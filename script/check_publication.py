#!/usr/bin/env python3
"""Check Git-visible files without printing secret values or changing the index.

Works before git init too. Existing tracked files are included even if ignored.
This is a focused safety check, not a comprehensive secret-scanning service.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
# Reviewed SwiftUI captures use example network data. A changed image must be
# visually reviewed (including metadata) before its digest is updated here.
REVIEWED_SCREENSHOTS = {
    'docs/images/overview.png': 'f824e67e86c4103b8a71473b1c5f93e4789f10a7a7a6183304312daea546f202',
    'docs/images/settings.png': '448086217ffc4f130b05a764ab7a1cde789ced9349823c942700b76a384d4de6',
}
REQUIRED_IGNORES = (
    'work/validation/status.json', 'work/private-archive/notes.md',
    'dist/RouteWeaver.app/Contents/Info.plist', '.build/cache',
    '.env', '.env.production', 'signing.p12', 'secret.key',
    '.codex/config.toml', 'debug.log', 'capture.har', '.DS_Store',
)
PATTERNS = (
    ('home directory path', re.compile(r'/(?:Users|home)/[A-Za-z0-9_.-]+/')),
    ('private key', re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----')),
    ('service token', re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,}|tskey-[A-Za-z0-9_-]{20,}|sk-(?:proj-)?[A-Za-z0-9_-]{30,})')),
    ('specific Tailnet name', re.compile(r'\btail[0-9a-f]{6,}\.ts\.net\b', re.I)),
    ('credential assignment', re.compile(r'''(?i)["']?(?:password|api_key|access_token|client_secret)["']?\s*[:=]\s*["'][A-Za-z0-9_+/=-]{16,}["']''')),
)


def check(git, list_files=False):
    def run(*args, input=None, accepted=(0,)):
        result = subprocess.run(git + list(args), cwd=ROOT, input=input, capture_output=True)
        if result.returncode not in accepted:
            raise RuntimeError('Git inspection failed: ' + ' '.join(args[:2]))
        return result.stdout

    # Documentation links to this repository intentionally include its owner.
    # Exempt only that exact HTTPS URL prefix from the account-name heuristic;
    # all credential and home-directory checks still inspect the original text.
    origin = run('config', '--get', 'remote.origin.url', accepted=(0, 1)).decode().strip()
    github_origin = re.fullmatch(r'(?:https://github\.com/|git@github\.com:)([A-Za-z0-9-]+/[A-Za-z0-9_.-]+)/?', origin)
    repository_url = None
    if github_origin:
        repository = github_origin.group(1).removesuffix('.git')
        repository_url = re.compile(r'https://github\.com/' + re.escape(repository) + r'''(?:\.git)?(?=[/#?\s"'<>)]|$)''')

    candidates = sorted(set(run('ls-files', '--cached', '--others', '--exclude-standard', '-z').split(b'\0')) - {b''})
    issues = []
    probes = [item.encode() for item in REQUIRED_IGNORES]
    ignored = set(run('check-ignore', '--no-index', '-z', '--stdin', input=b'\0'.join(probes) + b'\0', accepted=(0, 1)).split(b'\0'))
    for item in probes:
        if item not in ignored:
            issues.append((os.fsdecode(item), 'required ignore missing'))
    if candidates:
        tracked_ignored = set(run('check-ignore', '--no-index', '-z', '--stdin', input=b'\0'.join(candidates) + b'\0', accepted=(0, 1)).split(b'\0')) - {b''}
        for item in tracked_ignored:
            issues.append((os.fsdecode(item), 'already tracked despite ignore; remove from index'))
    for item in candidates:
        name = os.fsdecode(item)
        path = ROOT / name
        if path.is_symlink():
            issues.append((name, 'symlink requires review'))
            continue
        if not path.is_file():
            issues.append((name, 'missing or non-regular tracked file'))
            continue
        payload = path.read_bytes()
        if name in REVIEWED_SCREENSHOTS:
            if hashlib.sha256(payload).hexdigest() != REVIEWED_SCREENSHOTS[name]:
                issues.append((name, 'screenshot changed; review pixels and metadata'))
            continue
        if name == 'Assets/AppIcon.png':
            continue  # Reviewed source artwork; other binary files need review.
        try:
            content = payload.decode('utf-8')
        except UnicodeDecodeError:
            issues.append((name, 'unreviewed binary file'))
            continue
        for label, pattern in PATTERNS:
            match = pattern.search(content)
            if match:
                line = content.count('\n', 0, match.start()) + 1
                issues.append((f'{name}:{line}', label))
        local_user = Path.home().name
        if len(local_user) >= 4 and local_user not in ('root', 'user', 'runner'):
            account_content = content
            if name.endswith('.md') and repository_url:
                account_content = repository_url.sub('https://github.com/<repository>', account_content)
            if name == 'Sources/RouteWeaver/Views/SettingsView.swift':
                # The About author and GitHub profile are explicitly public.
                # Only this declaration is exempt from the account-name heuristic;
                # all secret/path checks above still inspect the complete file.
                account_content = re.sub(r'^\s*AboutSection\(version: version, author: "[^"\n]+", authorURL: URL\(string: "https://github\.com/[A-Za-z0-9-]+"\)\)\s*$', '', content, flags=re.M)
            if re.search(r'(?<![A-Za-z0-9])' + re.escape(local_user) + r'(?![A-Za-z0-9])', account_content, re.I):
                issues.append((name, 'local account name requires review'))
    if list_files:
        print('\n'.join(os.fsdecode(item) for item in candidates))
    for name, reason in issues:
        print(f'FAIL {name}: {reason}')
    print(f'{"FAIL" if issues else "PASS"}: {len(candidates)} Git-visible files; {len(issues)} findings. No files staged or uploaded.')
    return 1 if issues else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--list', action='store_true', help='show candidate paths, never file contents')
    args = parser.parse_args()
    if (ROOT / '.git').exists():
        return check(['git'], args.list)
    with tempfile.TemporaryDirectory(prefix='routeweaver-publication-') as directory:
        subprocess.run(['git', 'init', '--bare', '--quiet', directory], check=True, capture_output=True)
        return check(['git', '--git-dir=' + directory, '--work-tree=' + str(ROOT)], args.list)


if __name__ == '__main__':
    raise SystemExit(main())
