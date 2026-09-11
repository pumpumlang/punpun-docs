#!/usr/bin/env python3
"""Build the PunPun documentation site.

The generated site is committed at the repository root so GitHub Pages can
serve it directly. Only `*.html`, `assets/` and `search.json` are generated;
every other path in the repository is hand-maintained source.
"""
from __future__ import annotations
import argparse
from html import escape
import json
from pathlib import Path
import re, shutil, sys

ROOT=Path(__file__).resolve().parent
CONTENT=ROOT/'content'; DIST=ROOT; STATIC=ROOT/'static'
VERSION=(ROOT/'VERSION').read_text(encoding='utf-8').strip()

NAV_GROUPS=[
    ('Start here',['index','getting-started','language','functions','control-flow']),
    ('Intermediate',['objects','generics-results','packages','ppx-publishing','ppx-security','memory','errors']),
    ('Build real things',['requests','json','gui','async']),
    ('Advanced',['toolchains','injection','performance','self-hosting','editor-icons','api-reference']),
]
LEARNING_ORDER=['index','getting-started','language','functions','control-flow','objects','generics-results','packages','memory']
LEVELS={
    'index':'Learning path','getting-started':'Beginner','language':'Beginner','functions':'Beginner','control-flow':'Beginner',
    'objects':'Intermediate','generics-results':'Intermediate','packages':'Intermediate','ppx-publishing':'Intermediate','memory':'Intermediate',
}

def inline(text:str)->str:
    text=escape(text)
    text=re.sub(r'`([^`]+)`',r'<code>\1</code>',text)
    text=re.sub(r'\[([^]]+)\]\(([^)]+)\)',r'<a href="\2">\1</a>',text)
    return text

def markdown(src:str)->tuple[str,str]:
    out=[]; title='PunPun'; lines=src.splitlines(); i=0; in_code=False; code=[]; lang=''; list_open=False
    while i<len(lines):
        line=lines[i]
        if line.startswith('```'):
            if not in_code:
                if list_open: out.append('</ul>'); list_open=False
                in_code=True; lang=line[3:].strip(); code=[]
            else:
                body=escape('\n'.join(code)); cls=f' class="language-{escape(lang)}"' if lang else ''
                runnable=' data-runnable="true"' if lang in {'punpun','pp'} else ''
                out.append(f'<div class="code-wrap"{runnable}><div class="code-bar"><span>{escape(lang or "text")}</span><button class="copy" aria-label="Copy code">Copy</button></div><pre><code{cls}>{body}</code></pre></div>')
                in_code=False
            i+=1; continue
        if in_code: code.append(line); i+=1; continue
        if line.startswith('# '):
            if title=='PunPun': title=line[2:].strip()
            out.append(f'<h1>{inline(line[2:].strip())}</h1>')
        elif line.startswith('## '): out.append(f'<h2>{inline(line[3:].strip())}</h2>')
        elif line.startswith('### '): out.append(f'<h3>{inline(line[4:].strip())}</h3>')
        elif line.startswith('- '):
            if not list_open: out.append('<ul>'); list_open=True
            out.append(f'<li>{inline(line[2:].strip())}</li>')
        elif not line.strip():
            if list_open: out.append('</ul>'); list_open=False
        else:
            if list_open: out.append('</ul>'); list_open=False
            out.append(f'<p>{inline(line.strip())}</p>')
        i+=1
    if list_open: out.append('</ul>')
    return '\n'.join(out),title

def nav_html(pages:dict[str,dict], current:str)->str:
    rendered=[]; used=set()
    for label,slugs in NAV_GROUPS:
        links=[]
        for slug in slugs:
            page=pages.get(slug)
            if not page: continue
            used.add(slug)
            active=' aria-current="page" class="active"' if slug==current else ''
            links.append(f'<a href="{slug}.html"{active}>{escape(page["title"])}</a>')
        if links:
            rendered.append(f'<section class="nav-section"><div class="nav-label">{escape(label)}</div>{"".join(links)}</section>')
    extras=[p for slug,p in sorted(pages.items()) if slug not in used]
    if extras:
        links=[]
        for p in extras:
            active=' aria-current="page" class="active"' if p['slug']==current else ''
            links.append(f'<a href="{p["slug"]}.html"{active}>{escape(p["title"])}</a>')
        rendered.append(f'<section class="nav-section"><div class="nav-label">Reference</div>{"".join(links)}</section>')
    return ''.join(rendered)

def learning_neighbors(slug:str, pages:dict[str,dict]):
    if slug not in LEARNING_ORDER: return None,None
    index=LEARNING_ORDER.index(slug)
    previous=upcoming=None
    if index>0 and LEARNING_ORDER[index-1] in pages: previous=pages[LEARNING_ORDER[index-1]]
    if index+1<len(LEARNING_ORDER) and LEARNING_ORDER[index+1] in pages: upcoming=pages[LEARNING_ORDER[index+1]]
    return previous,upcoming

def template(page,body,nav,previous,next_page):
    slug=page['slug']; title=page['title']; level=LEVELS.get(slug,'Reference')
    prev_html=f'<a class="pager-card prev" href="{previous["slug"]}.html"><span>Previous</span><strong>{escape(previous["title"])}</strong></a>' if previous else '<span></span>'
    next_html=f'<a class="pager-card next" href="{next_page["slug"]}.html"><span>Next</span><strong>{escape(next_page["title"])}</strong></a>' if next_page else '<span></span>'
    return f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="description" content="PunPun {VERSION} language documentation"><title>{escape(title)} · PunPun</title><link rel="stylesheet" href="assets/site.css"></head>
<body><header><a class="brand" href="index.html"><img src="assets/punpun-mark.svg" alt="PunPun"><span class="brand-name">PunPun</span><span class="version">{VERSION}</span></a><div class="head-actions"><input id="search" placeholder="Search docs…" aria-label="Search documentation"><button id="theme" aria-label="Toggle theme">◐</button></div></header>
<div class="layout"><aside><nav>{nav}</nav><div id="results"></div></aside><main><div class="page-meta"><span>{escape(level)}</span><span>.pp documentation</span></div><article>{body}</article><div class="pager">{prev_html}{next_html}</div><footer>Examples are written for PunPun {VERSION}. Planned behavior is labeled rather than presented as shipped.</footer></main></div><script src="assets/site.js"></script></body></html>'''

ASSET_SOURCES=('site.css','site.js','punpun-mark.svg')


def render_site()->dict[str,str]:
    """Return every generated path (relative to the repo root) and its content."""
    generated={}
    for name in ASSET_SOURCES:
        generated[f'assets/{name}']=(STATIC/name).read_text(encoding='utf-8')
    pages={}
    for path in sorted(CONTENT.glob('*.md')):
        body,title=markdown(path.read_text(encoding='utf-8')); slug=path.stem
        pages[slug]={'slug':slug,'title':title,'body':re.sub('<[^>]+>',' ',body)[:12000],'html':body}
    for slug,page in pages.items():
        previous,next_page=learning_neighbors(slug,pages)
        generated[f'{slug}.html']=template(page,page['html'],nav_html(pages,slug),previous,next_page)
    search_order=[]
    seen=set()
    for _,slugs in NAV_GROUPS:
        for slug in slugs:
            if slug in pages and slug not in seen: search_order.append(pages[slug]); seen.add(slug)
    search_order.extend(p for slug,p in sorted(pages.items()) if slug not in seen)
    generated['search.json']=json.dumps([{k:p[k] for k in ('slug','title','body')} for p in search_order])
    return generated


def main()->int:
    parser=argparse.ArgumentParser(description='build the PunPun documentation site')
    parser.add_argument('--check',action='store_true',help='verify the committed site matches the sources')
    args=parser.parse_args()
    generated=render_site()

    if args.check:
        stale=[name for name,content in sorted(generated.items())
               if not (DIST/name).is_file() or (DIST/name).read_text(encoding='utf-8')!=content]
        orphans=sorted(p.name for p in DIST.glob('*.html') if p.name not in generated)
        if stale or orphans:
            if stale: print('stale generated pages: '+', '.join(stale),file=sys.stderr)
            if orphans: print('orphaned generated pages: '+', '.join(orphans),file=sys.stderr)
            print('run `python3 build.py` and commit the result',file=sys.stderr)
            return 1
        print(f'documentation site is current ({len(generated)} generated files)')
        return 0

    # Remove previously generated output only; hand-maintained sources stay put.
    for path in DIST.glob('*.html'): path.unlink()
    shutil.rmtree(DIST/'assets',ignore_errors=True)
    (DIST/'assets').mkdir()
    for name,content in generated.items():
        (DIST/name).write_text(content,encoding='utf-8')
    pages=sum(1 for name in generated if name.endswith('.html'))
    print(f'built {pages} documentation pages -> {DIST}')
    return 0


if __name__=='__main__': raise SystemExit(main())
