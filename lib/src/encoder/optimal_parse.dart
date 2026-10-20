/// Bounded dynamic-programming (optimal-ish) parse for qualities 10 and 11.
///
/// This is the bounded variant of the reference's HQ / Zopfli pass
/// (`c/enc/backward_references_hq.c`): a shortest-path DP over the block where
/// literals and copies are edges priced by a [ParseCostModel]. Unlike the lazy
/// parsers - which keep one candidate per position - the DP can defer a copy by
/// several literals and still consider longer/shorter copy lengths, which is
/// what makes quality 10/11 beat the lazy parse on English text.
///
/// The match options come from [HashChainMatcher.findLongestMatch] (the scored
/// best match at a position), with all lengths from 2 to that match, plus the
/// full length. The DP is linear in the block size: one match search and a
/// bounded number of length relaxations per position.
///
/// The result is an extra candidate: the encoder serialises it and keeps it
/// only when it is smaller, so it can never enlarge a block. The search is
/// rolled back through the matcher journal, so later blocks see the same match
/// table state as if the DP had not run.
///
/// [searchMask] (one byte per position) restricts where match searches happen;
/// the caller marks the previous parse's literal positions and copy starts. That
/// keeps the pass to a few hundred milliseconds per megabyte instead of
/// searching every position.
library;

import 'dart:typed_data';

import 'backward_references.dart' show kHashTypeLength;
import 'command.dart';
import 'cost_model.dart';
import 'match_finder.dart';

/// Longest copy length for which every intermediate length is relaxed.
const int _kMaxEnumeratedLength = 24;

/// Hard cap on copy lengths considered by the DP (long matches are still tried
/// at their full length).
const int _kMaxCopyLength = 1 << 16;

/// Largest number of pending literals tracked by the DP (matches the reference's
/// practical insert-length range; beyond this the insert code is already wide).
const int _kMaxInsertLength = 1 << 16;

/// Fills [commands] with a cost-optimal parse of `input[start .. start + size)`.
///
/// [hasher] must be primed with the positions before [start] (the caller keeps
/// it across blocks); the journal must be started by the caller so the DP's
/// speculative inserts can be rolled back.
void createOptimalBackwardReferences(
  Uint8List input,
  int start,
  int size,
  HashChainMatcher hasher,
  CommandBuffer commands,
  Int32List distanceCache,
  int maxBackwardLimit,
  ParseCostModel model, {
  Uint8List? searchMask,
  Int32List? knownCopyLen,
  Int32List? knownCopyDist,
  int searchStride = 1,
  int maxCandidates = 24,
  int maxSearchLength = 768,
}) {
  commands.clear();
  final end = start + size;
  if (size < 16) {
    commands.addInsertOnly(size);
    return;
  }
  final numDistances = hasher.numLastDistances;
  prepareDistanceCache(distanceCache, numDistances);

  // DP state: one entry per input position.
  final costs = Float64List(size + 1);
  final fromPos = Int32List(size + 1);
  final copyLen = Int32List(size + 1);
  final copyDist = Int32List(size + 1);
  final insertLen = Int32List(size + 1);
  for (var i = 0; i <= size; i++) {
    costs[i] = double.infinity;
    fromPos[i] = -1;
  }
  costs[0] = 0;
  final sr = HasherSearchResult()..reset(kMinScore);

  for (var i = 0; i <= size; i++) {
    final base = costs[i];
    if (base == double.infinity) continue;
    final pos = start + i;
    if (i == size) break;

    // Literal edge.
    {
      final literalCost = base + model.literalCost[input[pos]];
      final next = i + 1;
      if (literalCost < costs[next]) {
        costs[next] = literalCost;
        fromPos[next] = i;
        copyLen[next] = 0;
        copyDist[next] = 0;
        final pending = insertLen[i] + 1;
        insertLen[next] = pending < _kMaxInsertLength
            ? pending
            : _kMaxInsertLength;
      }
    }

    // Copy edges. Positions the previous parse never considered (inside a
    // copy) are skipped when a search mask is supplied: the DP then refinements
    // concentrate on literal runs and copy boundaries, which keeps the pass
    // within the quality tier's time budget.
    final searchable = (searchMask == null || searchMask[i] != 0) &&
        (searchStride <= 1 || i % searchStride == 0);
    final knownLength = knownCopyLen != null ? knownCopyLen[i] : 0;
    if (!searchable && knownLength == 0) continue;
    if (pos + kHashTypeLength >= end) continue;
    final maxLength = end - pos;
    final maxDistance = pos < maxBackwardLimit ? pos : maxBackwardLimit;
    if (maxDistance <= 0) continue;
    var length = knownLength;
    var distance = knownLength > 0 ? knownCopyDist![i] : 0;
    if (searchable) {
      final searchLimit = maxLength < maxSearchLength
          ? maxLength
          : maxSearchLength;
      sr.reset(kMinScore);
      hasher.findLongestMatch(
        input,
        distanceCache,
        numDistances,
        pos,
        searchLimit,
        maxDistance,
        sr,
        maxCandidates: maxCandidates,
      );
      if (sr.score > kMinScore && sr.len > length) {
        length = sr.len;
        distance = sr.distance;
      }
    }
    // A distance seeded from the previous parse is only valid at its own copy
    // start; if the DP starts the copy earlier it can exceed the window.
    if (distance > maxDistance) length = 0;
    if (length < 2) continue;
    final distanceCode = distance + numDistanceShortCodes - 1;
    final pending = insertLen[i];
    final limit = length < _kMaxEnumeratedLength
        ? length
        : _kMaxEnumeratedLength;
    for (var len = 2; len <= limit; len++) {
      final candidate = base + model.copyCost(pending, len, distanceCode);
      final next = i + len;
      if (candidate < costs[next]) {
        costs[next] = candidate;
        fromPos[next] = i;
        copyLen[next] = len;
        copyDist[next] = distance;
        insertLen[next] = 0;
      }
    }
    if (length > limit && length <= _kMaxCopyLength) {
      final candidate = base + model.copyCost(pending, length, distanceCode);
      final next = i + length;
      if (candidate < costs[next]) {
        costs[next] = candidate;
        fromPos[next] = i;
        copyLen[next] = length;
        copyDist[next] = distance;
        insertLen[next] = 0;
      }
    }
  }

  // Reconstruct the path: collect segments backward, emit them forward.
  var pathEnd = size;
  while (pathEnd > 0 && fromPos[pathEnd] < 0) {
    pathEnd--;
  }
  final segments = <List<int>>[];
  var index = pathEnd;
  while (index > 0) {
    final previous = fromPos[index];
    if (previous < 0) break;
    segments.add(<int>[previous, index, copyLen[index], copyDist[index]]);
    index = previous;
  }
  var pos = start;
  var pendingLiterals = 0;
  for (var s = segments.length - 1; s >= 0; s--) {
    final segment = segments[s];
    final segmentStart = start + segment[0];
    final segmentEnd = start + segment[1];
    final length = segment[2];
    pendingLiterals += segmentStart - pos;
    pos = segmentStart;
    if (length == 0) {
      // Literal step: its byte is part of the pending literal run.
      continue;
    }
    final codingMaxDistance = pos < maxBackwardLimit
        ? pos
        : maxBackwardLimit;
    commands.addCopy(
      pendingLiterals,
      length,
      segment[3],
      codingMaxDistance,
      distanceCache,
    );
    pendingLiterals = 0;
    pos = segmentEnd;
  }
  pendingLiterals += end - pos;
  if (pendingLiterals > 0) commands.addInsertOnly(pendingLiterals);
}