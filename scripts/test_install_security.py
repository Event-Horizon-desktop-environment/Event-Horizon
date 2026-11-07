#!/usr/bin/env python3
"""Verify install branches reject share symlinks before changing either tree."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    """Exercise real and dangling links against the actual privileged snippet."""
    blocks = (ROOT / 'build.sh').read_text().split("run_privileged sh -c '\n")
    script = next(
        b for b in blocks if 'repo=$1' in b and 'stage=$3' in b
    ).split("\n    ' sh")[0]
    for name in ('icons', 'templates'):
        for dangling in (False, True):
            with tempfile.TemporaryDirectory(prefix='eh-install-security-') as directory:
                work = Path(directory)
                repo = work / 'repo'
                stage = work / 'stage'
                repo.mkdir()
                stage.mkdir()
                if name == 'icons':
                    icons = stage / 'icons/hicolor/scalable/apps'
                    icons.mkdir(parents=True)
                    (icons / 'horizon.svg').write_text('icon')
                else:
                    source = repo / 'zig-out/share/event-horizon'
                    source.mkdir(parents=True)
                    (source / 'config.toml').write_text('template')
                prefix = work / 'prefix'
                prefix.mkdir()
                target = work / 'target'
                if not dangling:
                    old = target / 'event-horizon'
                    old.mkdir(parents=True)
                    (old / 'sentinel').write_text('preserve this file')
                (prefix / 'share').symlink_to(target, target_is_directory=True)
                # No privilege is needed: a valid guard exits before any install
                # command. Trace assertions ensure permission failures cannot mask
                # a missing guard when this test is run by an ordinary user.
                result = subprocess.run(
                    ['sh', '-ex', '-c', script, 'sh',
                     str(repo), str(prefix), str(stage)],
                    cwd=work, capture_output=True, text=True,
                )
                assert result.returncode != 0, result.stderr
                commands = result.stderr.splitlines()
                last = commands[-1]
                assert last.startswith('+ test ') and last.endswith(f'-L {prefix}/share'), result.stderr
                assert (prefix / 'share').is_symlink()
                if dangling:
                    assert not target.exists()
                else:
                    assert (target / 'event-horizon/sentinel').read_text() == 'preserve this file'
                    assert sorted(str(p.relative_to(target)) for p in target.rglob('*')) == [
                        'event-horizon', 'event-horizon/sentinel',
                    ]
                print(f'PASS {name}: {"dangling" if dangling else "existing"} share symlink')


if __name__ == '__main__':
    main()
