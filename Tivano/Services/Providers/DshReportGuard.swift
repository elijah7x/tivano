/// The installed dsh-tools guard runs after extensible pre-execute policy and cannot
/// be force-allowed by another guard. Verified against dsh 0.2.1-rc.2; the ready event
/// is sent only after guard and prompt-filter registration both succeed.
enum DshReportGuard {
    static let source = #"""
    export const name = 'tivano-report-guard';
    export const inject = ['tools', 'systemPrompt'];
    export function apply(ctx) {
      if (typeof ctx.tools.guard !== 'function') {
        throw new Error('Tivano final report requires tools.guard');
      }
      ctx.tools.guard(() => 'Tools are disabled for the final report. Report the work already completed without calling tools.');
      ctx.on('system-prompt/assemble', async (_assembly, _context, next) => {
        const assembly = await next();
        return { ...assembly, tools: [] };
      }, { prepend: true });
      process.stdout.write(JSON.stringify({ jsonrpc: '2.0', method: 'tivano/report_guard_ready', params: { version: 1 } }) + '\n');
    }
    """#
}
