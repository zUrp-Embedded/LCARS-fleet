"""Build a complete, bounded proposal from inventory.tsv; run from repository root."""
from pathlib import Path
import csv, collections, re
ROOT = Path('maintenance/elixir-doc-cleanup')
rows = list(csv.DictReader((ROOT/'inventory.tsv').open(), delimiter='\t'))
for r in rows:
    for k in list(r):
        if k != 'path': r[k] = int(r[k])
pilot = {'runtime/lib/fleet/spawner.ex', 'runtime/lib/fleet/spawner/pod.ex', 'runtime/lib/fleet/spawner/supervisor.ex'}
# Group by domain, then by review topic for the largest domains. No file is split.
def identity(path):
    p = path.removeprefix('runtime/')
    if p.startswith('lib/fleet/'):
        return p.removeprefix('lib/fleet/').removesuffix('.ex')
    if p.startswith('test/fleet/'):
        return p.removeprefix('test/fleet/').removesuffix('_test.exs')
    return None

def family(r):
    p=r['path']; k=identity(p)
    if p in pilot: return '00 — Pilote spawner déjà préparé'
    if k is None:
        if '/test/support/pilot/' in p: return '19 — Pilot : harnais de tests'
        if '/test/support/spawner/' in p: return '01 — Spawner : cycle de vie et supervision'
        if '/test/support/forge/' in p: return '11 — Forge : client et opérations'
        if '/test/support/' in p or p.endswith('/test_helper.exs'): return '26 — Infrastructure des tests'
        if p.endswith('/test/mix/gate_composition_test.exs'): return '27 — Configuration et construction'
        if '/lib/mix/' in p or '/test/mix/' in p:
            leaf=Path(p).name
            if any(x in leaf for x in ['tools', 'tool_descriptions', 'tool_effects', 'capabilities_exercisable']): return '25d — Mix : contrats des outils'
            if any(x in leaf for x in ['single_source', 'layout_single_source', 'forge_fields', 'seam_surface', 'cap_profile_project_keys', 'proven_image']): return '25c — Mix : sources de vérité et déclarations'
            if any(x in leaf for x in ['runtime', 'events', 'boot', 'artifact', 'eval_doors', 'bare_alias']): return '25b — Mix : contrats runtime et artefacts'
            if any(x in leaf for x in ['support', 'tests.', 'test_corpora', 'tests_corpus', 'no_check_passes', 'derniers_murs', 'contracts']): return '25e — Mix : infrastructure des contrôles'
            return '25a — Mix : commandes et catalogue' 
        return '27 — Configuration et construction'
    if k=='spawner' or k.startswith('spawner/'):
        t=k.removeprefix('spawner/')
        if re.search(r'launch|egress|mcp_provision|mcp_socket|assets|scaffold|brief|session_files|skills',t): return '02 — Spawner : provisioning et lancement'
        if re.search(r'seed|session|pool|recovery|state_fs|boot_epoch',t): return '03 — Spawner : identité et persistance'
        if re.search(r'kick|wake|liveness|turn_flag|task_probe|publishing|completed_payload|events',t): return '04 — Spawner : activité et résultats'
        return '01 — Spawner : cycle de vie et supervision'
    if k.startswith(('project_bootstrap','sp_builder','modops_consumption')): return '08 — Prompts et préparation des workspaces'
    if k.startswith(('cap_profile','catalogue','loader_envelope','schema_cache')): return '06 — Catalogue et profils'
    if k.startswith('credentials'): return '07 — Identités et credentials'
    if k.startswith('event_router') or k=='event' or k.startswith('task_queue') or k.startswith('publish/'): return '09 — Événements et file de travail'
    if k.startswith(('layout','toolchain')): return '05 — Chemins et toolchain'
    if k.startswith('conflict'): return '10 — Analyse des conflits'
    if k.startswith('forge'): return '11 — Forge : client et opérations'
    if k.startswith('workflow'): return '12 — Workflow : contrats et artefacts'
    if k.startswith('roster'): return '12 — Workflow : contrats et artefacts'
    if k.startswith('project/onboard'): return '14 — Projets : onboarding'
    if k.startswith('project'): return '13 — Projets : déclaration et maintenance'
    if k.startswith('mcp'):
        if re.search(r'delegation|dependency|dependencies|create_issue|delete_project|retire_issue|scratch|toolchain_request|issue_status', k): return '16 — MCP : délégation métier'
        return '15 — MCP : transport et outils pods'
    if k.startswith('pilot'):
        t=k.removeprefix('pilot/')
        if t.startswith(('poller','offload','pod_reaper')): return '18 — Pilot : admission et réconciliation'
        if 'review_lifecycle' in t: return '21 — Pilot : revue et remédiation'
        if t.startswith(('step_dispatcher','brief_builder')): return '20 — Pilot : dispatch et briefs'
        if t.startswith(('step_run','completion_outbox','workflow_map_nav')): return '22 — Pilot : résultats et progression'
        if t.startswith(('merge','conflict')): return '23 — Pilot : fusion et conflits'
        if t.startswith(('incident','arch_','pod_feed','wake_recovery')): return '17 — Pilot : coordination, incidents et réveils'
        return '17 — Pilot : coordination, incidents et réveils'
    if k.startswith(('api','observation')): return '24 — API et observation'
    if k.startswith(('admiral','application')): return '24b — Démarrage et arrêt de la flotte'
    if k.startswith(('config_knobs','runtime_exs','seam_key')): return '27 — Configuration et construction'
    if k=='os_probe': return '26 — Infrastructure des tests'
    return '05b — Primitives et formats partagés'

families=collections.defaultdict(list)
for r in rows: families[family(r)].append(r)
# Exact source/test pairs stay together. For the other tests the manifest retains
# the domain/topic, without claiming that filename matching proves dependency.
batches=[]
for name, group in sorted(families.items()):
    if name.startswith('00'):
        batches.append((name,group));continue
    units=collections.defaultdict(list)
    for r in group: units[identity(r['path']) or r['path']].append(r)
    current=[]
    for _,unit in sorted(units.items()):
        trial=current+unit
        if current and (len(trial)>12 or sum(r['base_prose_lines'] for r in trial)>900 or sum(r['base_lines'] for r in trial)>5000):
            batches.append((name,current));current=[]
        current+=unit
    if current:batches.append((name,current))
assert len({r['path'] for _,b in batches for r in b}) == len(rows)
assert sum(len(b) for _,b in batches)==len(rows)
manifest=[]; summary=[]
for i,(name,group) in enumerate(batches):
    lot=f'L{i:02d}'; paths=sorted(r['path'] for r in group)
    for r in sorted(group,key=lambda r:r['path']): manifest.append({'lot':lot,'family':name,'path':r['path'],'base_lines':r['base_lines'],'base_prose_lines':r['base_prose_lines'],'current_prose_lines':r['current_prose_lines']})
    summary.append({'lot':lot,'family':name,'files':len(group),'lines':sum(r['base_lines'] for r in group),'prose':sum(r['base_prose_lines'] for r in group),'current_prose':sum(r['current_prose_lines'] for r in group),'doctest_prompts':sum(r['base_doctest_prompts'] for r in group)})
for filename,content in [('batches.tsv',manifest),('batch-summary.tsv',summary)]:
    with (ROOT/filename).open('w') as f:
        w=csv.DictWriter(f,fieldnames=list(content[0]),delimiter='\t');w.writeheader();w.writerows(content)
for name in sorted(families):
    bs=[r for r in summary if r['family']==name]
    print(f"{bs[0]['lot']}–{bs[-1]['lot']} | {name} | {sum(r['files'] for r in bs)} fichiers | {sum(r['prose'] for r in bs)} doc | {len(bs)} lots")
print('TOTAL',len(batches),'lots; maxima',max(r['files'] for r in summary),max(r['prose'] for r in summary),max(r['lines'] for r in summary))
