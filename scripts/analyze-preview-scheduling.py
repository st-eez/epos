#!/usr/bin/env python3
"""Summarize silent Swift scheduler replays; no native performance claim."""
import argparse
import base64
import json
import math
from collections import defaultdict
from pathlib import Path


def percentile(values, fraction):
    ordered = sorted(values)
    if not ordered:
        return 0.0
    position = (len(ordered) - 1) * fraction
    lower = int(position)
    return ordered[lower] + (ordered[math.ceil(position)] - ordered[lower]) * (position - lower)


def stale_intervals(row):
    events = [(p['milliseconds'], 0, p['text']) for p in row['publications']]
    events += [(c['milliseconds'], 1, c['line']) for c in row['commands']]
    end = row['completionMilliseconds']
    events = sorted(event for event in events if event[0] <= end)
    desired, prefix, draft = '', '', ''
    stale_since = None
    intervals = []
    for timestamp, kind, value in events:
        if kind == 0:
            desired = value
        else:
            command, _, payload = value.partition(' ')
            if command == 'mark':
                draft = payload
            elif command in ('seal', 'commit', 'commit64'):
                prefix += base64.b64decode(payload).decode() if command == 'commit64' else payload
                draft = ''
            elif command == 'cancel':
                draft = ''
        normalize = lambda text: text.replace('\r', ' ').replace('\n', ' ')
        stale = normalize(prefix + draft) != normalize(desired)
        if stale and stale_since is None:
            stale_since = timestamp
        elif not stale and stale_since is not None:
            intervals.append(timestamp - stale_since)
            stale_since = None
    if stale_since is not None:
        intervals.append(end - stale_since)
    return intervals


def summarize(rows, captures):
    if not rows or not captures:
        raise ValueError('captures and replays must both contain evidence')
    expected = {(r['file'], r['repeatIndex']) for r in captures}
    assert len(expected) == len(captures), 'duplicate input recording/repeat'
    grouped = defaultdict(list)
    paired = defaultdict(dict)
    for row in rows:
        key = (row['file'], row['repeatIndex'])
        interval = row['throttleMilliseconds']
        assert key in expected and interval in (100, 33, 16, 0), 'unexpected replay'
        assert interval not in paired[key], 'duplicate replay'
        assert row['route'] == 'completed(Epos.FinalInsertionResult.accepted, viaIME: true)', row['route']
        assert all(math.isfinite(row[name]) for name in ('releaseMilliseconds', 'completionMilliseconds'))
        assert row['completionMilliseconds'] >= row['releaseMilliseconds'] >= 0
        paired[key][interval] = row
        grouped[(row['repeatIndex'], interval)].append(row)
    assert set(paired) == expected, 'missing recording/repeat'
    for arms in paired.values():
        assert set(arms) == {100, 33, 16, 0}, 'missing schedule'
        assert len({r['delivered'] for r in arms.values()}) == 1, 'delivered text changed'
    results = []
    for (repeat, interval), group in sorted(grouped.items()):
        recording_intervals = [stale_intervals(row) for row in group]
        intervals = [duration for durations in recording_intervals for duration in durations]
        elapsed = sum(row['completionMilliseconds'] for row in group)
        results.append({
            'repeatIndex': repeat, 'throttleMilliseconds': interval, 'recordings': len(group),
            'marks': sum(sum(c['line'].startswith('mark ') for c in row['commands']) for row in group),
            'staleMilliseconds': sum(intervals), 'staleFraction': sum(intervals) / elapsed,
            'staleIntervalP95Milliseconds': percentile(intervals, .95),
            'stalePerRecordingP95Milliseconds': percentile([sum(durations) for durations in recording_intervals], .95),
            'releaseToCompletionP95Milliseconds': percentile([
                row['completionMilliseconds'] - row['releaseMilliseconds'] for row in group], .95),
            'eventProcessingP95Milliseconds': percentile([
                value for row in group for value in row['eventProcessingMilliseconds']], .95),
        })
    candidates = []
    for interval in (33, 16, 0):
        gates = []
        for repeat in sorted({r['repeatIndex'] for r in rows}):
            baseline = next(r for r in results if r['repeatIndex'] == repeat and r['throttleMilliseconds'] == 100)
            candidate = next(r for r in results if r['repeatIndex'] == repeat and r['throttleMilliseconds'] == interval)
            gates.append({
                'repeatIndex': repeat,
                'staleP95GainMilliseconds': baseline['staleIntervalP95Milliseconds'] - candidate['staleIntervalP95Milliseconds'],
                'markRatio': candidate['marks'] / baseline['marks'],
                'releaseP95DeltaMilliseconds': candidate['releaseToCompletionP95Milliseconds'] - baseline['releaseToCompletionP95Milliseconds'],
            })
        passed = all(g['staleP95GainMilliseconds'] >= 20 and g['markRatio'] <= 1.25
                     and g['releaseP95DeltaMilliseconds'] <= 5 for g in gates)
        candidates.append({'throttleMilliseconds': interval, 'passesReplayScreen': passed, 'gates': gates})
    return {'replays': len(rows), 'identicalPairedDelivery': True, 'summaries': results,
            'candidates': candidates, 'nativeRenderingCostMeasured': False}


def self_test():
    row = {'publications': [{'milliseconds': 10, 'text': 'a'}, {'milliseconds': 20, 'text': 'ab'}],
           'commands': [{'milliseconds': 30, 'line': 'mark ab'}, {'milliseconds': 40, 'line': 'seal ab'}],
           'completionMilliseconds': 40}
    assert stale_intervals(row) == [20], 'superseded draft must remain in stale time'
    row['commands'].insert(0, {'milliseconds': 15, 'line': 'mark a'})
    assert stale_intervals(row) == [5, 10]
    assert percentile([0, 10], .95) == 9.5
    capture = {'file': 'fixture', 'repeatIndex': 0}
    rows = [
        dict(row, **capture, throttleMilliseconds=interval,
             route='completed(Epos.FinalInsertionResult.accepted, viaIME: true)',
             releaseMilliseconds=35, eventProcessingMilliseconds=[1], delivered='ab')
        for interval in (100, 33, 16, 0)
    ]
    assert summarize(rows, [capture])['replays'] == 4
    invalid = [
        rows[:-1],
        rows + rows[:1],
        rows[:-1] + [dict(rows[-1], delivered='lost text')],
        rows[:-1] + [dict(rows[-1], route='fallback')],
    ]
    for case in invalid:
        try:
            summarize(case, [capture])
        except AssertionError:
            continue
        raise AssertionError('invalid replay accepted')
    for replays, captures in (([], []), ([], [capture]), (rows, [])):
        try:
            summarize(replays, captures)
        except ValueError:
            continue
        raise AssertionError('empty evidence accepted')
    print('PASS: superseded draft timing, percentiles, paired coverage, delivery and route checks')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--captures', type=Path)
    parser.add_argument('--replays', type=Path)
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if not args.captures or not args.replays:
        parser.error('--captures and --replays are required')
    read = lambda path: [json.loads(line) for line in path.read_text().splitlines() if line]
    print(json.dumps(summarize(read(args.replays), read(args.captures)), indent=2))


if __name__ == '__main__':
    main()
