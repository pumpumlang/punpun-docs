#!/usr/bin/env python3
"""Structural checks for the documentation content.

The learning-path pages follow a fixed shape so readers can move between them
without re-learning the layout. Every one of them must also carry a complete,
compilable PunPun example.

The example is compiled when a PunPun compiler is available, which is what
makes this more than a formatting check. Point `PUNPUN_PPC` at a `ppc` binary
(or put one on `PATH`) to get that coverage; without one the compile step is
skipped and only the structure is verified.
"""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CONTENT = ROOT / 'content'
LEARNING_PAGES = ['index', 'getting-started', 'language', 'functions',
                  'control-flow', 'objects', 'generics-results', 'memory']
REQUIRED_SECTIONS = ['## Overview', '## Syntax', '## Runnable example',
                     '## Common mistakes', '## Next steps']


def find_compiler() -> str | None:
    override = os.environ.get('PUNPUN_PPC')
    if override:
        return override if Path(override).is_file() else None
    found = shutil.which('ppc')
    if found:
        return found
    sibling = ROOT.parent / 'punpun' / 'build' / 'ppc'
    return str(sibling) if sibling.is_file() else None


class LearningDocumentationTests(unittest.TestCase):
    def test_core_learning_pages_share_structure(self):
        compiler = find_compiler()
        for slug in LEARNING_PAGES:
            with self.subTest(page=slug):
                page = CONTENT / f'{slug}.md'
                self.assertTrue(page.is_file(), f'{page} is missing')
                text = page.read_text(encoding='utf-8')
                for heading in REQUIRED_SECTIONS:
                    self.assertIn(heading, text)
                runnable = text.split('## Runnable example', 1)[1].split('## Common mistakes', 1)[0]
                match = re.search(r'```(?:punpun|pp)\n(.*?)\n```', runnable, re.S)
                self.assertIsNotNone(
                    match, 'Runnable example must include a complete PunPun code block')
                if not compiler:
                    continue
                with tempfile.TemporaryDirectory() as td:
                    path = Path(td) / f'{slug}.pp'
                    path.write_text(match.group(1) + '\n', encoding='utf-8')
                    result = subprocess.run([compiler, 'check', str(path)],
                                            text=True, capture_output=True)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_marked_doctest_blocks_compile_and_run(self):
        compiler = find_compiler()
        fence = re.compile(r"^```(?:punpun|pp)\s+(doctest|doctest-run)\s*$\n(.*?)^```\s*$",
                           re.I | re.M | re.S)
        found = 0
        for page in sorted([*CONTENT.rglob('*.md'), *(ROOT / 'reference').rglob('*.md')]):
            for mode, source in fence.findall(page.read_text(encoding='utf-8')):
                found += 1
                if not compiler:
                    continue
                with self.subTest(page=page.name, block=found):
                    with tempfile.TemporaryDirectory() as td:
                        path = Path(td) / 'main.pp'
                        path.write_text(source, encoding='utf-8')
                        action = 'run' if mode.lower() == 'doctest-run' else 'check'
                        result = subprocess.run([compiler, action, str(path)],
                                                cwd=td, text=True, capture_output=True, timeout=60)
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertGreater(found, 0, 'expected at least one marked doctest block')

    def test_every_page_has_a_title(self):
        for page in sorted(CONTENT.glob('*.md')):
            with self.subTest(page=page.name):
                first = page.read_text(encoding='utf-8').lstrip().splitlines()[0]
                self.assertTrue(first.startswith('# '),
                                f'{page.name} must start with a single `# Title` heading')


if __name__ == '__main__':
    unittest.main()
