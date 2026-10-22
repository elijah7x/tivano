enum DshMarketplaceBootstrap {
    static var errorMessages: [String: String] {
        [
            "read": AppText.localized("Cannot read marketplace input: %@"),
            "changed": AppText.localized("The DeepSeek Harness profile changed while preparing this session. Try again."),
            "format": AppText.localized("Cannot read %@. Check its format, installation and permissions."),
            "version": AppText.localized("Read-only marketplace inheritance currently requires DeepSeek Harness 0.2.1-rc.2."),
            "home": AppText.localized("The DeepSeek Harness home changed during launch. Restart with a consistent DSH_HOME."),
            "selection": AppText.localized("Invalid bundle selection in %@/package.json"),
            "exemptions": AppText.localized("Invalid version exemptions in %@/compatibility.json"),
            "bundle": AppText.localized("Bundle %@ has no dsh.bundle declaration."),
            "compatibility": AppText.localized("Bundle %@ is incompatible with this DeepSeek Harness version."),
            "resolution": AppText.localized("Cannot resolve the selected marketplace bundles and their installed dependencies."),
            "patch": AppText.localized("A patch in %@ targets a missing or incompatible ACP row. Desktop-only overrides are not supported."),
            "acp": AppText.localized("The ACP boundary row %@ was changed or disabled."),
            "entry": AppText.localized("Unsupported Cordis entry: %@"),
            "plugin": AppText.localized("Cannot resolve enabled plugin %@."),
            "dynamic": AppText.localized("Dynamic plugin module names are not supported by read-only marketplace inheritance."),
            "surface": AppText.localized("Plugin %@ requires an unsupported desktop, Web, HMR, Include or Worker surface."),
            "group": AppText.localized("Dynamic group %@ is not supported by read-only marketplace inheritance."),
            "admission": AppText.localized("Plugin %@ failed runtime compatibility admission."),
            "activation": AppText.localized("An enabled marketplace or ACP plugin could not activate. Check required host services and installed dependencies."),
            "stopped": AppText.localized("The read-only marketplace host stopped before ACP became ready."),
            "startup": AppText.localized("Read-only marketplace startup failed. Check the selected bundles and their ACP compatibility."),
            "readonly": AppText.localized("Tivano inherits this DeepSeek Harness profile read-only. Change installed plugins, bundle selections and version exemptions in DeepSeek Harness, then restart this session."),
        ]
    }

    static let source = #"""
    import fs from 'node:fs';
    import path from 'node:path';
    import { createRequire, registerHooks } from 'node:module';
    import { fileURLToPath, pathToFileURL } from 'node:url';
    import { createHash } from 'node:crypto';

    const run = path.dirname(fileURLToPath(import.meta.url));
    const options = JSON.parse(fs.readFileSync(path.join(run, 'options.json'), 'utf8'));
    const anchor = path.join(options.runtime, 'node_modules/@deepseek-ai/dsh/package.json');
    const require = createRequire(anchor);
    const load = name => import(pathToFileURL(require.resolve(name)).href);
    class AdmissionError extends Error {}
    const fail = message => { throw new AdmissionError(message); };
    const message = (key, value) => options.errors[key].replace('%@', () => String(value));
    const readonly = message('readonly');
    const fingerprints = new Map();
    function stamp(file) {
        try {
            // Electron synthesizes a new inode for each ASAR member stat call.
            const archive = file.indexOf('.asar/');
            const stat = archive < 0 ? fs.statSync(file) : require('original-fs').statSync(file.slice(0, archive + 5));
            return `${stat.dev}:${stat.ino}:${stat.size}:${stat.mtimeMs}:` + createHash('sha256').update(fs.readFileSync(file)).digest('hex');
        } catch (error) {
            if (error.code === 'ENOENT') return null;
            fail(message('read', file));
        }
    }
    function track(file) {
        const value = stamp(file);
        if (fingerprints.has(file) && fingerprints.get(file) !== value) fail(message('changed'));
        fingerprints.set(file, value);
    }
    function unchanged() {
        for (const [file, value] of fingerprints) if (stamp(file) !== value) fail(message('changed'));
    }
    function read(label, operation) {
        try { return operation(); }
        catch (error) {
            if (error instanceof AdmissionError) throw error;
            // Native YAML/JSON errors may quote credentials from the input.
            fail(message('format', label));
        }
    }
    let ctx;
    let disposeProxy;
    async function main() {
        // Mirrors desktop-host's Office resolver: native child processes cannot read ASAR members.
        const runtimeRoot = fs.realpathSync(options.runtime);
        const archive = path.dirname(runtimeRoot);
        const officeSource = pathToFileURL(path.join(runtimeRoot, 'node_modules/@deepseek-ai/libreoffice-kit-')).href;
        const officeDestination = pathToFileURL(path.join(archive + '.unpacked', path.relative(archive, runtimeRoot), 'node_modules/@deepseek-ai/libreoffice-kit-')).href;
        registerHooks({ resolve(specifier, context, next) {
            const result = next(specifier, context);
            if (!result.url.startsWith('file:') || (!/^@deepseek-ai\/libreoffice-kit-(?:darwin|win32|linux)-/u.test(specifier) && !/\/node_modules\/@deepseek-ai\/libreoffice-kit-(?:darwin|win32|linux)-[^/]+\//u.test(new URL(result.url).pathname))) return result;
            const canonical = pathToFileURL(fs.realpathSync(fileURLToPath(result.url))).href;
            if (!canonical.startsWith(officeSource)) {
                if (canonical.startsWith(pathToFileURL(archive + '/').href)) fail(message('resolution'));
                return result;
            }
            return { ...result, url: pathToFileURL(fs.realpathSync(fileURLToPath(officeDestination + canonical.slice(officeSource.length)))).href };
        } });
        const boot = await load('@deepseek-ai/dsh-app-boot');
        if (boot.getDshRuntimeVersion() !== '0.2.1-rc.2') fail(message('version'));
        const { Context } = await load('@deepseek-ai/cordis');
        const { default: Loader } = await load('@deepseek-ai/cordis-plugin-loader');
        const { default: Group } = await load('@deepseek-ai/cordis-plugin-group');
        const { Include } = await load('@deepseek-ai/cordis-plugin-include');
        const { dshHomePath, resolveDshHome } = await load('@deepseek-ai/dsh-home-paths');
        const { DSH_LAUNCH_ENVIRONMENT_KEY } = await load('@deepseek-ai/dsh-launch-environment');
        const { provideCmdline } = await load('@deepseek-ai/dsh-cmdline');
        const { installProxyFromEnvironment } = await load('@deepseek-ai/dsh-http-proxy');
        const environment = boot.loadLayeredEnv('dsh', process.cwd(), () => {});
        if (fs.realpathSync(resolveDshHome()) !== fs.realpathSync(options.home)) fail(message('home'));
        const source = options.source;
        const sourceBase = pathToFileURL(source + path.sep).href;
        track(path.join(source, 'package.json'));
        const manifest = read(`profile manifest ${source}`, () => boot.readProfileManifest('dsh', source));
        if ((manifest.dsh !== undefined && (manifest.dsh === null || typeof manifest.dsh !== 'object')) || (manifest.dsh?.profile !== undefined && (manifest.dsh.profile === null || typeof manifest.dsh.profile !== 'object'))) fail(message('selection', source));
        const selected = manifest.dsh?.profile?.bundles ?? [];
        if (!Array.isArray(selected) || selected.some(name => typeof name !== 'string') || new Set(selected).size !== selected.length) fail(message('selection', source));
        track(path.join(source, 'compatibility.json'));
        const compatibility = read(`compatibility file ${source}`, () => boot.readProfileCompatibility(source));
        if (compatibility.warnings.length) fail(message('exemptions', source));
        fs.writeFileSync(path.join(run, 'compatibility.json'), JSON.stringify(compatibility.exemptions), { mode: 0o600 });
        const layers = [];
        function patches(file, optional = false) {
            track(file);
            if (optional && fingerprints.get(file) === null) return [];
            return read(`patch ${file}`, () => boot.loadOverlayPatches('dsh', file));
        }
        function bundle(name) {
            const directory = read(`bundle ${name}`, () => boot.resolveBundleDir('dsh', name, anchor, source));
            track(path.join(directory, 'package.json'));
            const data = read(`bundle manifest ${name}`, () => boot.readProfileManifest('dsh', directory));
            if (!data.dsh?.bundle) fail(message('bundle', name));
            const issue = boot.evaluatePluginCompatibility(data, compatibility.exemptions);
            if (issue && !issue.exempted) fail(message('compatibility', name));
            const patchPaths = read(`bundle patch paths ${name}`, () => boot.bundlePatchPaths(directory, data.dsh.bundle));
            const layer = { packageName: name, packageDir: directory, patchPaths, patches: patchPaths.flatMap(file => patches(file)) };
            layers.push(layer);
            return layer;
        }
        const base = ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-acp-app'];
        for (const name of base) bundle(name);
        // rc.2 desktop uses web-app as its surface; do not exclude other official bundles.
        const surfaces = new Set(['@deepseek-ai/dsh-web-app']);
        for (const name of selected) if (!base.includes(name) && !surfaces.has(name)) bundle(name);
        const profile = { name: path.basename(source), dir: source, layers, patchPath: path.join(source, 'cordis.patch.yml'), patches: [], skippedBundles: [] };
        const resolution = await boot.createRuntimeResolution({ installAnchor: anchor, profile, home: options.home }).catch(() => fail(message('resolution')));
        // Plain resolution data deliberately has no computeLatestResolution/refresh path.
        const frozenResolution = Object.freeze({ profilesDir: resolution.profilesDir, profileDir: resolution.profileDir, localPackageNames: resolution.localPackageNames, linkedRoots: resolution.linkedRoots, entries: resolution.entries });
        for (const entry of resolution.entries) track(path.join(entry.packageDir, 'package.json'));
        const inputs = layers.map(layer => ({ label: layer.packageName, patches: layer.patches }));
        const inheritedRows = boot.composeEntries(inputs.map(input => input.patches));
        const optionalDesktopUI = new Set(['ui-settings-account', 'ui-chat', 'ui-settings']);
        const userPatches = patches(profile.patchPath, true).filter(patch =>
            !optionalDesktopUI.has(patch.id) || inheritedRows.some(row => row.id === patch.id));
        inputs.push({ label: profile.patchPath, patches: userPatches });
        const homePatch = path.join(options.home, 'cordis.patch.yml');
        inputs.push({ label: homePatch, patches: patches(homePatch, true) });
        for (const file of options.overlays) {
            let overlay = patches(file);
            if (path.basename(file) === 'minimal-optional.yml') {
                const before = boot.composeEntries(inputs.map(input => input.patches));
                if (!before.some(row => row.id === 'tool-working-directory')) overlay = overlay.filter(patch => patch.id !== 'tool-working-directory');
            }
            inputs.push({ label: file, patches: overlay });
        }
        // Prefixes identify the offending source; the final tree still uses one flattened pass.
        for (let index = 0; index < inputs.length; index++) boot.composeEntries(inputs.slice(0, index + 1).map(input => input.patches), () => fail(message('patch', inputs[index].label)));
        let rows = boot.composeEntries(inputs.map(input => input.patches));
        const telemetry = boot.resolveTelemetryPatch(process.env.DSH_TELEMETRY_DISABLED, rows.some(row => row.id === 'session-telemetry-otel'));
        if (telemetry) rows = boot.composeEntries([[{ insert: rows }, telemetry]]);
        for (const [id, name] of [['acp', '@deepseek-ai/dsh-acp'], ['acp-app-startup', '@deepseek-ai/dsh-acp-app']]) {
            const matches = rows.filter(row => row.id === id);
            if (matches.length !== 1 || matches[0].name !== name || matches[0].disabled) fail(message('acp', id));
        }
        ctx = new Context();
        ctx.baseUrl = sourceBase;
        ctx.provide('dshHomePath', dshHomePath);
        ctx.provide(DSH_LAUNCH_ENVIRONMENT_KEY, environment);
        ctx.provide('profileContext', Object.freeze({ name: 'tivano-readonly', dir: run, patchPath: path.join(run, 'cordis.patch.yml'), installAnchor: anchor, startedBundles: layers.map(layer => layer.packageName), cwd: process.cwd(), home: options.home, overlays: [], telemetryDisabledEnv: process.env.DSH_TELEMETRY_DISABLED }));
        await ctx.plugin(Loader);
        await ctx.plugin(boot.PluginPackages, { resolution: frozenResolution });
        const packages = ctx.get('pluginPackages');
        const forbidden = new Set(['@deepseek-ai/dsh-web-app', '@deepseek-ai/dsh-host-webserver', '@deepseek-ai/dsh-schedule', '@deepseek-ai/dsh-host-product-telemetry-otel', '@deepseek-ai/dsh-hmr', '@deepseek-ai/dsh-client-hmr', '@deepseek-ai/dsh-client-modules', '@deepseek-ai/dsh-client-connection', '@deepseek-ai/dsh-client-file-upload', '@deepseek-ai/dsh-cordis-client-runner', '@deepseek-ai/cordis-plugin-include', '@deepseek-ai/cordis-plugin-worker']);
        function identity(name) {
            if (name === 'cordis:group') return name;
            if (name.startsWith('cordis:')) fail(message('entry', name));
            if (name.startsWith('file:') || path.isAbsolute(name)) {
                let directory = path.dirname(name.startsWith('file:') ? fileURLToPath(name) : name);
                while (true) {
                    const file = path.join(directory, 'package.json');
                    if (fs.existsSync(file)) {
                        const manifest = read(`plugin manifest ${file}`, () => JSON.parse(fs.readFileSync(file, 'utf8')));
                        const issue = boot.evaluatePluginCompatibility(manifest, compatibility.exemptions);
                        if (issue && !issue.exempted) fail(message('admission', name));
                        return manifest.name ?? name;
                    }
                    const parent = path.dirname(directory);
                    if (parent === directory) return name;
                    directory = parent;
                }
            }
            const pkg = packages.packageOf(name, sourceBase);
            if (!pkg) fail(message('plugin', name));
            const issue = boot.evaluatePluginCompatibility(pkg.manifest, compatibility.exemptions);
            if (issue && !issue.exempted) fail(message('admission', name));
            return pkg.name;
        }
        function admit(name) {
            if (typeof name !== 'string') fail(message('dynamic'));
            const id = identity(name);
            if (forbidden.has(id)) fail(message('surface', name));
            if (id === '@deepseek-ai/dsh-plugin-manager' && !name.endsWith('/tools')) fail(readonly);
        }
        // Keep the official management tool but replace its service, not merely its UI.
        rows = rows.filter(row => !(row.id === 'plugin-manager' && row.name === '@deepseek-ai/dsh-plugin-manager'));
        function walk(entries) {
            for (const row of entries) {
                if (row.disabled === true && !row.group) continue;
                admit(row.name);
                if (row.group === true || row.name === 'cordis:group' || row.name === '@deepseek-ai/cordis-plugin-group') {
                    if (!Array.isArray(row.config)) fail(message('group', row.id ?? row.name));
                    walk(row.config);
                }
            }
        }
        walk(rows);
        const checked = boot.prepareProfileEntries(ctx, rows, sourceBase);
        function compare(original, prepared) {
            for (let i = 0; i < original.length; i++) {
                if (original[i].disabled !== true && prepared[i].disabled === true) fail(message('admission', original[i].id ?? original[i].name));
                if (original[i].group && Array.isArray(original[i].config)) compare(original[i].config, prepared[i].config);
            }
        }
        compare(rows, checked);
        rows = checked;
        const deny = () => { throw new AdmissionError(readonly); };
        ctx.provide('pluginManager', Object.freeze({
            listPlugins: async () => [...ctx.loader.entries()].filter(entry => entry.options.id !== 'include').map(entry => ({ entryId: entry.id, name: entry.options.name, enabled: !entry.disabled, active: entry.fiber?.state === 2, readonly: true })),
            listBundles: async () => layers.map(layer => ({ packageName: layer.packageName, enabled: true, readonly: true, removable: false })),
            listVersionExemptions: () => ({ exemptions: structuredClone(compatibility.exemptions), warnings: [] }),
            setPluginEnabled: deny, setBundleEnabled: deny, installBundle: deny, removeBundle: deny, setVersionExemption: deny,
        }));
        class ReadonlyRoot extends Include {
            constructor(context, config) {
                super(context, config);
                this.ctx.baseUrl = sourceBase;
                this.readonly = true;
            }
            async read() { this.data = []; this.content = '[]'; return true; }
            async refresh() { fail(readonly); }
            async _writeFile() { fail(readonly); }
            // Loader disposal may persist its current tree; this root is deliberately ephemeral.
            write() {}
            import(name, outer) {
                admit(name);
                const specifier = path.isAbsolute(name) ? pathToFileURL(name).href : name;
                if (name.startsWith('cordis:')) return super.import(specifier, outer);
                return this.ctx.loader.internal.import(specifier, sourceBase, {});
            }
        }
        ctx.loader.builtins.include = ReadonlyRoot;
        ctx.loader.builtins.group = Group;
        const importRoot = ctx.loader.import.bind(ctx.loader);
        let rootPending = true;
        ctx.loader.import = (name, outer) => {
            if (name === 'cordis:include' && rootPending) rootPending = false;
            else admit(name);
            return importRoot(name, outer);
        };
        let ready = false;
        const listeners = new Set();
        let closing;
        const shutdown = code => {
            if (closing) return closing;
            const timer = setTimeout(() => process.exit(code), 5000);
            closing = Promise.resolve().then(() => ctx?.fiber.dispose()).finally(() => { disposeProxy?.(); clearTimeout(timer); process.exitCode = code; });
            return closing;
        };
        provideCmdline(ctx, { args: [], exit: code => void shutdown(code), ready: { onReady(listener) { if (ready) listener(); else listeners.add(listener); return () => listeners.delete(listener); } } });
        process.on('SIGTERM', () => { if (closing) process.exit(0); void shutdown(0); });
        process.on('SIGINT', () => { if (closing) process.exit(130); void shutdown(130); });
        boot.installFailLoud('dsh', process, () => shutdown(1));
        unchanged();
        disposeProxy = await installProxyFromEnvironment(environment, () => {});
        await ctx.loader.create({ id: 'include', name: 'cordis:include', config: { path: pathToFileURL(path.join(run, 'cordis.yml')).href, patches: [{ insert: rows }] } });
        await ctx.loader.await();
        await boot.auditStartupEntries(ctx, 'dsh');
        // An enabled entry left pending waits on services a headless ACP host never
        // provides — desktop-only plugins like the Inspector — and its inactive
        // context later breaks session setup with -32603. Removing the entry
        // matches stock dsh's absent-bundle shape; real failures still reject below.
        const pending = [];
        for (const entry of ctx.loader.entries()) {
            try { if (entry.disabled) continue; } catch { fail(message('activation')); }
            if (entry.id.includes(':') && entry.fiber !== undefined && entry.fiber.state === 0) pending.push(entry);
        }
        for (const entry of pending) {
            const missing = Object.keys(entry.fiber.inject).filter(service => entry.fiber.ctx.get(service) === undefined);
            process.stderr.write(`dsh: dropping ${entry.options.id} (${entry.options.name}); an ACP host provides no ${missing.join(', ') || 'required services'}\n`);
            await entry.parent.remove(entry.options.id);
        }
        for (const entry of ctx.loader.entries()) {
            try { if (entry.disabled) continue; } catch { fail(message('activation')); }
            if (entry.fiber === undefined || entry.fiber.state !== 2) fail(message('activation'));
        }
        unchanged();
        if (ctx.fiber.state !== 2 || !ctx.get('loader')) fail(message('stopped'));
        ready = true;
        for (const listener of listeners) listener();
        listeners.clear();
    }
    try { await main(); }
    catch (error) {
        try { await ctx?.fiber.dispose(); } catch {}
        try { await disposeProxy?.(); } catch {}
        process.stderr.write(`dsh: ${error instanceof AdmissionError ? error.message : message('startup')}\n`);
        process.exit(1);
    }
    """#
}
