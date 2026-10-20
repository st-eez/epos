#!/usr/bin/env python3
"""Compare acknowledged native updates; timestamps do not measure display scanout."""
import argparse
import copy
import hashlib
import importlib.util
import json
import math
import statistics
import tempfile
from pathlib import Path


source = Path(__file__).with_name('analyze-preview-scheduling.py')
spec = importlib.util.spec_from_file_location('preview_scheduling', source)
replay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(replay)


def cpu_milliseconds(before, after):
    assert before['processStart'] == after['processStart'], 'native process restarted'
    for key in ('timebaseNumerator', 'timebaseDenominator'):
        assert before[key] == after[key] and before[key] > 0, 'invalid native clock'
    delta = after['userTime'] + after['systemTime'] - before['userTime'] - before['systemTime']
    assert delta >= 0, 'CPU counter went backwards'
    return delta * before['timebaseNumerator'] / before['timebaseDenominator'] / 1e6


def measurements(row):
    commands = row['commands']
    assert commands and all(c['reply'].startswith('ok') for c in commands), 'native refusal'
    assert sum(c['line'] == 'commit EPOS final token' for c in commands) == 1, 'wrong final command'
    assert not any(c['line'].startswith(('seal', 'cancel', 'commit64')) for c in commands), 'unexpected native route'
    assert len(row['publications']) == 25, 'incomplete publication workload'
    lateness = [p['milliseconds'] - p['scheduledMilliseconds'] for p in row['publications']]
    assert all(math.isfinite(value) and value >= 0 for value in lateness), 'invalid publication timing'
    previous_ack = 0
    for command in commands:
        sent, ack = command['sentMilliseconds'], command['milliseconds']
        assert math.isfinite(sent) and math.isfinite(ack) and previous_ack <= sent <= ack, 'overlapping or invalid commands'
        previous_ack = ack
    assert 0 <= row['releaseMilliseconds'] <= row['completionMilliseconds']
    stale = replay.stale_intervals(row)
    marks = [c for c in commands if c['line'].startswith('mark ')]
    assert marks, 'no native marks'
    cpu = {name: cpu_milliseconds(row['nativeUsageBefore'][name], row['nativeUsageAfter'][name])
           for name in ('ghostty', 'companion')}
    return {
        'pair': row['pair'], 'interval': row['throttleMilliseconds'], 'marks': len(marks),
        'staleIntervalP95Milliseconds': replay.percentile(stale, .95),
        'staleMilliseconds': sum(stale),
        'publicationLatenessP95Milliseconds': replay.percentile(lateness, .95),
        'markReplyP95Milliseconds': replay.percentile([c['milliseconds'] - c['sentMilliseconds'] for c in marks], .95),
        'releaseMilliseconds': row['completionMilliseconds'] - row['releaseMilliseconds'],
        'nativeCPUMilliseconds': cpu,
        'nativeCPUPercentOfOneCore': sum(cpu.values()) / row['completionMilliseconds'] * 100,
        'transportCallPendingAtRelease': row['transportCallPendingAtRelease'],
    }


def analyze(directory):
    rows = [json.loads(line) for line in (directory / 'native-replays.jsonl').read_text().splitlines()]
    assert len(rows) == 12, 'twelve native trials required'
    indexed = {(row['pair'], row['throttleMilliseconds']): row for row in rows}
    assert set(indexed) == {(pair, interval) for pair in range(6) for interval in (0, 100)}, 'incomplete paired trials'
    for pair in range(6):
        workloads = [[(p['text'], p['scheduledMilliseconds']) for p in indexed[(pair, arm)]['publications']]
                     for arm in (100, 0)]
        assert workloads[0] == workloads[1], 'different paired workloads'
    state = json.loads((directory / 'terminal.json').read_text())
    expected = b'x' + b'EPOS final token' * 13
    assert state['byteCount'] == len(expected) and state['sha256'] == hashlib.sha256(expected).hexdigest(), 'wrong terminal bytes'
    assert (directory / 'complete').exists(), 'native run incomplete'
    measurements(json.loads((directory / 'visual.json').read_text()))
    measured = [measurements(row) for row in rows]
    pairs = []
    for pair in range(6):
        baseline = next(m for m in measured if m['pair'] == pair and m['interval'] == 100)
        candidate = next(m for m in measured if m['pair'] == pair and m['interval'] == 0)
        pairs.append({
            'pair': pair,
            'staleP95GainMilliseconds': baseline['staleIntervalP95Milliseconds'] - candidate['staleIntervalP95Milliseconds'],
            'releaseDeltaMilliseconds': candidate['releaseMilliseconds'] - baseline['releaseMilliseconds'],
            'nativeCPUPercentDelta': candidate['nativeCPUPercentOfOneCore'] - baseline['nativeCPUPercentOfOneCore'],
            'replyP95DeltaMilliseconds': candidate['markReplyP95Milliseconds'] - baseline['markReplyP95Milliseconds'],
            'publicationLatenessP95DeltaMilliseconds': abs(candidate['publicationLatenessP95Milliseconds']
                                                          - baseline['publicationLatenessP95Milliseconds']),
        })
    summaries = []
    for interval in (100, 0):
        group = [m for m in measured if m['interval'] == interval]
        summaries.append({
            'interval': interval, 'trials': len(group), 'marks': sum(m['marks'] for m in group),
            'medianStaleP95Milliseconds': statistics.median(m['staleIntervalP95Milliseconds'] for m in group),
            'medianReplyP95Milliseconds': statistics.median(m['markReplyP95Milliseconds'] for m in group),
            'medianReleaseMilliseconds': statistics.median(m['releaseMilliseconds'] for m in group),
            'medianNativeCPUPercentOfOneCore': statistics.median(m['nativeCPUPercentOfOneCore'] for m in group),
        })
    gates = {
        'everyPairGains20Milliseconds': all(p['staleP95GainMilliseconds'] >= 20 for p in pairs),
        'releaseMedianWithin5Milliseconds': statistics.median(p['releaseDeltaMilliseconds'] for p in pairs) <= 5,
        'releaseEachWithin10Milliseconds': all(p['releaseDeltaMilliseconds'] <= 10 for p in pairs),
        'nativeCPUMedianWithin2PercentagePoints': statistics.median(p['nativeCPUPercentDelta'] for p in pairs) <= 2,
        'nativeCPUEachWithin5PercentagePoints': all(p['nativeCPUPercentDelta'] <= 5 for p in pairs),
        'replyMedianWithin5Milliseconds': statistics.median(p['replyP95DeltaMilliseconds'] for p in pairs) <= 5,
        'publicationLatenessP95Within10Milliseconds': all(m['publicationLatenessP95Milliseconds'] <= 10 for m in measured),
        'pairedPublicationLatenessWithin5Milliseconds': all(p['publicationLatenessP95DeltaMilliseconds'] <= 5 for p in pairs),
        'pendingTransportReleaseCovered': all(m['transportCallPendingAtRelease'] for m in measured if m['pair'] % 3 == 2),
    }
    return {'trials': measured, 'pairs': pairs, 'summaries': summaries, 'terminalBytesVerified': True,
            'gates': gates, 'passesNativeTimingScreen': all(gates.values()),
            'displayScanoutMeasured': False}


def self_test():
    before = dict(processStart=1, userTime=0, systemTime=0, timebaseNumerator=125, timebaseDenominator=3)
    after = dict(before, userTime=24_000)
    assert cpu_milliseconds(before, after) == 1
    for invalid in (dict(after, processStart=2), dict(after, timebaseNumerator=1), dict(after, userTime=-1)):
        try:
            cpu_milliseconds(before, invalid)
        except AssertionError:
            continue
        raise AssertionError('invalid native usage accepted')
    publications = [dict(text=str(i), milliseconds=i * 10, scheduledMilliseconds=i * 10) for i in range(25)]
    publications[-1]['text'] = 'EPOS final token'
    rows = []
    for pair in range(6):
        for interval in (100, 0):
            marks = [dict(line='mark ' + p['text'], reply='ok', sentMilliseconds=p['milliseconds'] + 1,
                          milliseconds=p['milliseconds'] + 2) for p in publications]
            if interval == 100:
                marks = [dict(line='mark EPOS final token', reply='ok', sentMilliseconds=319, milliseconds=320)]
            rows.append(dict(pair=pair, throttleMilliseconds=interval, publications=copy.deepcopy(publications),
                             commands=marks + [dict(line='commit EPOS final token', reply='ok',
                                                   sentMilliseconds=400, milliseconds=410)],
                             releaseMilliseconds=400, completionMilliseconds=410,
                             nativeUsageBefore={name: dict(before) for name in ('ghostty', 'companion')},
                             nativeUsageAfter={name: dict(after) for name in ('ghostty', 'companion')},
                             transportCallPendingAtRelease=True))
    expected = b'x' + b'EPOS final token' * 13
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        terminal = dict(byteCount=len(expected), sha256=hashlib.sha256(expected).hexdigest())
        (directory / 'terminal.json').write_text(json.dumps(terminal))
        (directory / 'complete').touch()
        (directory / 'visual.json').write_text(json.dumps(dict(rows[-1], pair=6)))

        def check(mutator=None, gate=None):
            changed = copy.deepcopy(rows)
            if mutator:
                mutator(changed)
            (directory / 'native-replays.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in changed))
            try:
                result = analyze(directory)
            except AssertionError:
                assert gate is None and mutator is not None, 'unexpected evidence rejection'
                return
            if gate:
                assert not result['gates'][gate] and not result['passesNativeTimingScreen'], gate
            else:
                assert mutator is None and result['passesNativeTimingScreen'], 'invalid evidence accepted'

        check()
        check(lambda data: data.pop())
        check(lambda data: data[0].update(pair=1))
        check(lambda data: data[0]['commands'][-1].update(line='commit wrong'))
        check(lambda data: data[0]['commands'][0].update(reply='error'))
        check(lambda data: data[1]['commands'][1].update(sentMilliseconds=0))
        check(lambda data: data[0]['publications'][0].update(text='different'))
        check(lambda data: data[4].update(transportCallPendingAtRelease=False), 'pendingTransportReleaseCovered')
        check(lambda data: data[0].update(commands=copy.deepcopy(data[1]['commands'])), 'everyPairGains20Milliseconds')
        for delay, gate in ((20, 'publicationLatenessP95Within10Milliseconds'),
                            (6, 'pairedPublicationLatenessWithin5Milliseconds')):
            check(lambda data: [p.update(milliseconds=p['milliseconds'] + delay) for p in data[0]['publications']], gate)
        for gate in ('releaseMedianWithin5Milliseconds', 'releaseEachWithin10Milliseconds'):
            check(lambda data: [row.update(completionMilliseconds=430) for row in data[1::2]], gate)
        for gate in ('nativeCPUMedianWithin2PercentagePoints', 'nativeCPUEachWithin5PercentagePoints'):
            check(lambda data: [row['nativeUsageAfter']['ghostty'].update(userTime=3_000_000)
                                for row in data[1::2]], gate)
        check(lambda data: [command.update(milliseconds=command['milliseconds'] + 6)
                            for row in data[1::2] for command in row['commands'][:-1]], 'replyMedianWithin5Milliseconds')
        for bad in (dict(terminal, byteCount=0), dict(terminal, sha256='wrong')):
            (directory / 'terminal.json').write_text(json.dumps(bad))
            check(lambda _: None)
    print('PASS: native CPU units, paired evidence, delivery, timing, coverage and acceptance gates')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path, nargs='?')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        self_test()
    elif args.directory:
        print(json.dumps(analyze(args.directory), indent=2))
    else:
        parser.error('provide a native run directory or --self-test')
