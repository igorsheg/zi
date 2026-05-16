#!/usr/bin/env python3
import pathlib, re
ROOT = pathlib.Path(__file__).resolve().parents[1]
SRC = ROOT / 'src' / 'coding_agent' / 'extensions'
text = '\n'.join(p.read_text(errors='ignore') for p in SRC.rglob('*.zig'))
required_zi = '''zi.version zi.version.api zi.version.host zi.extension zi.extension.id zi.extension.name zi.extension.root zi.extension.require zi.define zi.define.command zi.define.tool zi.define.keybinding zi.define.provider zi.define.event zi.define.action zi.json zi.json.encode zi.json.decode zi.schema zi.schema.object zi.schema.string zi.schema.number zi.schema.integer zi.schema.boolean zi.schema.array zi.schema.enum zi.doc zi.doc.schema zi.doc.version zi.doc.fragment zi.doc.span zi.doc.line zi.doc.text zi.doc.markdown zi.doc.group zi.doc.marker zi.doc.step zi.doc.is_fragment zi.doc.validate zi.doc.to_markdown'''.split()
required_ctx = '''ctx.capabilities ctx.env ctx.env.cwd ctx.env.workspace_id ctx.env.session_id ctx.env.session_file ctx.env.extension_id ctx.env.extension_root ctx.env.state_owner_id ctx.env.generation_id ctx.env.namespace_id ctx.control ctx.control.is_idle ctx.control.wait_for_idle ctx.control.abort ctx.control.signal ctx.control.signal.cancelled ctx.control.signal.reason ctx.control.signal.throw_if_cancelled ctx.chat ctx.chat.send_user ctx.chat.send_custom ctx.chat.has_pending ctx.session ctx.session.info ctx.session.name ctx.session.rename ctx.session.messages ctx.session.model_context ctx.session.tool_results ctx.session.entries ctx.session.entry ctx.session.append_entry ctx.session.notes ctx.session.notes.append ctx.session.notes.list ctx.session.artifacts ctx.session.artifacts.append ctx.session.artifacts.list ctx.session.labels ctx.session.labels.set ctx.session.labels.list ctx.state ctx.state.get ctx.state.set ctx.state.delete ctx.state.list ctx.models ctx.models.current ctx.models.list ctx.models.get ctx.ai ctx.ai.complete ctx.ai.session ctx.agent ctx.agent.run ctx.process ctx.process.run ctx.process.start ctx.process.job ctx.ui ctx.ui.capabilities ctx.ui.view ctx.ui.view.set ctx.ui.view.remove ctx.ui.view.clear ctx.ui.notify ctx.ui.notify.show ctx.ui.notify.update ctx.ui.notify.clear ctx.ui.notify.clear_group ctx.ui.notify.progress ctx.ui.surface ctx.ui.surface.frame ctx.composer ctx.composer.set_text ctx.composer.insert_text ctx.composer.clear ctx.events ctx.events.emit ctx.log ctx.log.debug ctx.log.info ctx.log.warn ctx.log.error'''.split()
forbidden = '''zi.command zi.tool zi.provider zi.unprovider zi.on zi.action zi.keybinding zi.system zi.spawn zi.job zi.job.start zi.job.write zi.job.stop zi.doc.render zi.doc.save zi.doc.load zi.doc.search ctx.cwd ctx.binding ctx.extension ctx.send_user_message ctx.send_message ctx.append_entry ctx.has_pending_messages ctx.ai.stream ctx.events.on ctx.control.shutdown ctx.ui.render ctx.ui.clear ctx.ui.frame ctx.ui.input ctx.ui.progress ctx.ui.view.patch'''.split()
# Runtime-surface proxy: exported v4 names should occur as string field installs or API names; forbidden old names should not occur outside spec/tests.
def has_path(path):
    parts = path.split('.')
    leaf = parts[-1]
    if re.search(r'"' + re.escape(leaf) + r'"', text): return True
    if path in ('zi.json','zi.doc'): return True
    return re.search(re.escape(path), text) is not None
required_missing = sum(1 for p in required_zi + required_ctx if not has_path(p))
forbidden_present = sum(1 for p in forbidden if re.search(re.escape(p), text) is not None)
reject_needles = ['handler', 'execute', 'parameters', 'desc', 'stdio', 'events', 'ui_frame', 'annote', 'ttl', 'notification', 'editor.border.top', 'editor.border.bottom', 'flex_direction', 'flex_grow', 'margin', 'z_index', 'position', 'flex_wrap', 'flex_shrink', 'flex_basis']
forbidden_accepted = sum(1 for n in reject_needles if not re.search(r'(reject|forbid|invalid|unknown|deprecated|old).*' + re.escape(n) + r'|' + re.escape(n) + r'.*(reject|forbid|invalid|unknown|deprecated|old)', text, re.I))
capability_failed = 0
for cap in ['ui','composer','surface','process','ai','agent','session','state','models','keybinding']:
    if not re.search(r'"' + cap + r'"', text): capability_failed += 1
for cap in ['view','notify','progress','focus','color','markdown','ansi']:
    if not re.search(r'"' + cap + r'"', text): capability_failed += 1
positive_failed = 0
for needle in ['define.command','define.tool','view.set','notify.show','process.run','process.start','models.current','ai.session']:
    if needle not in text: positive_failed += 1
negative_failed = forbidden_present + forbidden_accepted
total = required_missing + forbidden_present + forbidden_accepted + positive_failed + negative_failed + capability_failed
print(f'required_missing={required_missing}')
print(f'forbidden_present={forbidden_present}')
print(f'forbidden_accepted={forbidden_accepted}')
print(f'positive_failed={positive_failed}')
print(f'negative_failed={negative_failed}')
print(f'capability_failed={capability_failed}')
print(f'METRIC v4_conformance_failures={total}')
