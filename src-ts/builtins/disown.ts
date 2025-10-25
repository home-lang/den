import type { BuiltinCommand, CommandResult, Shell } from './types'

export const disownCommand: BuiltinCommand = {
  name: 'disown',
  description: 'Remove jobs from the job table',
  usage: 'disown [-h|--help] [job_spec ...]',
  examples: [
    'disown                 # disown the current job (%+)',
    'disown %1 %2           # disown jobs by id',
    'disown %+ %-            # disown current and previous jobs',
    'disown -h               # show help',
  ],
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()
    const jobs = shell.getJobs()

    if (jobs.length === 0) {
      return { exitCode: 0, stdout: '', stderr: '', duration: performance.now() - start }
    }

    // Help flag
    if (args.includes('-h') || args.includes('--help')) {
      const help = `Usage: disown [-h|--help] [job_spec ...]\n\n`
        + `Remove jobs from the job table without sending signals.\n\n`
        + `Job spec can be one of:\n`
        + `  %n   job number n\n`
        + `  %+   current job\n`
        + `  %-   previous job\n`
        + `  +|-  shorthand for %+ or %-\n`
      return { exitCode: 0, stdout: help, stderr: '', duration: performance.now() - start }
    }

    const parseDesignator = (token: string): number | undefined => {
      const t = token.trim()
      if (t === '%+' || t === '+') {
        const live = jobs.filter(j => j.status !== 'done')
        return live.length ? live[live.length - 1].id : undefined
      }
      if (t === '%-' || t === '-') {
        const live = jobs.filter(j => j.status !== 'done')
        return live.length >= 2 ? live[live.length - 2].id : undefined
      }
      const norm = t.startsWith('%') ? t.slice(1) : t
      const n = Number.parseInt(norm, 10)
      return Number.isNaN(n) ? undefined : n
    }

    const jobIds: number[] = args.length > 0
      ? args.map(a => parseDesignator(a)).filter((n): n is number => typeof n === 'number')
      : [jobs.filter(j => j.status !== 'done').slice(-1)[0]?.id].filter((n): n is number => typeof n === 'number')

    const errors: string[] = []
    if (shell.config.verbose)
      shell.log.debug('[disown] requested ids:', args.join(' '))
    for (const jid of jobIds) {
      const job = shell.getJob(jid)
      if (!job) {
        errors.push(`disown: ${jid}: no such job`)
        continue
      }
      if (typeof job.pid !== 'number') {
        errors.push(`disown: ${jid}: job has no pid`)
        continue
      }
      // Remove the job by its ID, not its PID (force removal for disown)
      const removed = shell.removeJob(job.id, true)
      if (!removed) {
        errors.push(`disown: ${jid}: failed to remove job`)
      }
    }

    return {
      exitCode: errors.length ? 1 : 0,
      stdout: '',
      stderr: errors.length ? `${errors.join('\n')}\n` : '',
      duration: performance.now() - start,
    }
  },
}
