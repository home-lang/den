import type { BuiltinCommand, CommandResult, Shell } from './types'

/**
 * Jobs command - lists background jobs
 * Shows job ID, status, and command for each background job
 */
export const jobsCommand: BuiltinCommand = {
  name: 'jobs',
  description: 'List background jobs',
  usage: 'jobs [-l]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()
    const showPid = args.includes('-l') || args.includes('--long')
    if (shell.config.verbose)
      shell.log.debug('[jobs] flags: %o', { l: showPid })

    // Get all jobs
    const jobs = shell.getJobs()
    if (shell.config.verbose)
      shell.log.debug('[jobs] listing %d job(s)', jobs.length)

    if (jobs.length === 0) {
      return {
        exitCode: 0,
        stdout: '',
        stderr: '',
        duration: performance.now() - start,
      }
    }

    // Determine current (%+) and previous (%-) among non-done jobs
    const live = jobs.filter(j => j.status !== 'done')
    const currentId = live.length ? live[live.length - 1].id : undefined
    const previousId = live.length >= 2 ? live[live.length - 2].id : undefined

    // Format job entries
    const jobEntries = jobs.map((job) => {
      let statusSymbol = ''
      if (job.status === 'done') {
        statusSymbol = 'Done'
      }
      else if (job.id === currentId) {
        statusSymbol = '+'
      }
      else if (job.id === previousId) {
        statusSymbol = '-'
      }
      else {
        statusSymbol = job.status === 'stopped' ? '-' : '+'
      }

      let line = `[${job.id}]${statusSymbol} ${job.status}`

      if (showPid && job.pid) {
        line += ` ${job.pid}`
      }

      line += ` ${job.command}`

      if (job.background) {
        line += ' &'
      }

      return line
    })

    const result: CommandResult = {
      exitCode: 0,
      stdout: `${jobEntries.join('\n')}\n`,
      stderr: '',
      duration: performance.now() - start,
    }
    if (shell.config.verbose)
      shell.log.debug('[jobs] done in %dms', Math.round(result.duration || 0))
    return result
  },
}
