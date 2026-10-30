#!/usr/bin/env python3
"""Repair cumulative Codex document-chat metrics from matching local transcript evidence.

Dry-run by default. --apply appends revisions with the same event ID, preserving
all original records. Only exact final totals and timestamps within five seconds
qualify; ambiguous or missing transcripts are left untouched.
"""
import argparse
import fcntl
import json
from datetime import datetime
from pathlib import Path


def instant(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00'))


def correction(event, started, transcripts):
    matches = []
    for rows in transcripts:
        counts = [r for r in rows if r.get('payload', {}).get('type') == 'token_count'
                  and r['payload'].get('info')]
        final = [r for r in counts
                 if r['payload']['info']['total_token_usage'].get('input_tokens') == event['actualInputTokens']
                 and r['payload']['info']['total_token_usage'].get('output_tokens') == event['actualOutputTokens']
                 and abs((instant(r['timestamp']) - instant(event['timestamp'])).total_seconds()) <= 5]
        if len(final) != 1:
            continue
        end = instant(final[0]['timestamp'])
        turns = []
        seen = set()
        for row in counts:
            info = row['payload']['info']
            identity = tuple(sorted(info['total_token_usage'].items()))
            if started <= instant(row['timestamp']) <= end and identity not in seen:
                turns.append(info['last_token_usage'])
            seen.add(identity)
        usage = {key: sum(t.get(key, 0) for t in turns)
                 for key in ['input_tokens', 'cached_input_tokens', 'output_tokens']}
        # Context compaction may report a context length without consumed tokens.
        if not usage['input_tokens'] or usage['input_tokens'] >= event['actualInputTokens']:
            continue
        revised = dict(event)
        revised.update(actualInputTokens=usage['input_tokens'],
                       cachedInputTokens=usage['cached_input_tokens'],
                       actualOutputTokens=usage['output_tokens'],
                       actualTotalTokens=usage['input_tokens'] + usage['output_tokens'],
                       correctionReason='Exclude inherited Codex lifetime totals; sum request transcript turns')
        matches.append(revised)
    return matches[0] if len(matches) == 1 else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--support', type=Path, default=Path.home() / 'Library/Application Support/ECC Focus Queue')
    parser.add_argument('--codex-home', type=Path, default=Path.home() / '.codex')
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    path = args.support / 'analytics/prompt-usage.jsonl'
    # Hold the same append lock as the app, preserving concurrent event writers.
    with path.open('a+') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        stream.seek(0)
        events = list({r['id']: r for r in map(json.loads, stream) if r}.values())
        candidates = [e for e in events if e.get('source') == 'document_chat'
                      and e.get('provider') == 'codex' and e.get('scope') == 'provider'
                      and not e.get('correctionReason')]
        transcripts = []
        for day in {e['timestamp'][:10].replace('-', '/') for e in candidates}:
            for file in (args.codex_home / 'sessions' / day).glob('*.jsonl'):
                rows = []
                with file.open() as source:
                    for line in source:
                        if '"token_count"' in line:
                            try:
                                rows.append(json.loads(line))
                            except ValueError:
                                pass
                transcripts.append(rows)
        revisions = []
        for event in candidates:
            starts = [instant(e['timestamp']) for e in events if e.get('runID') == event['runID']
                      and e.get('scope') != 'provider']
            revised = correction(event, min(starts), transcripts) if starts else None
            if revised:
                revisions.append(revised)
                print(json.dumps({'eventID': event['id'], 'before': event['actualTotalTokens'],
                                  'after': revised['actualTotalTokens']}))
        if args.apply:
            stream.seek(0, 2)
            for revised in revisions:
                stream.write(json.dumps(revised) + '\n')
            stream.flush()
        print(json.dumps({'applied': args.apply, 'corrections': len(revisions)}))


if __name__ == '__main__':
    main()
