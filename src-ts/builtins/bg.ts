import type { BuiltinCommand, CommandResult, Shell } from './types'

/**
 * Background command - resumes a suspended job in the background
 * Usage: bg [%job_id]
 */
export const bgCommand: BuiltinCommand = {
  name: 'bg',
  description: 'Resume suspended jobs in the background',
  usage: 'bg [%job_id]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()
    if (shell.config.verbose)
      shell.log.debug('[bg] args: %o', args)

    // Resolve job designator
    const parseDesignator = (token: string): number | undefined => {
      const t = token.trim()
      if (t === '%+' || t === '+') {
        // current job is the most recent non-done job
        const jobs = shell.getJobs().filter(j => j.status !== 'done')
        return jobs.length ? jobs[jobs.length - 1].id : undefined
      }
      if (t === '%-' || t === '-') {
        const jobs = shell.getJobs().filter(j => j.status !== 'done')
        return jobs.length >= 2 ? jobs[jobs.length - 2].id : undefined
      }
      const norm = t.startsWith('%') ? t.slice(1) : t
      const n = Number.parseInt(norm, 10)
      return Number.isNaN(n) ? undefined : n
    }

    let jobId: number | undefined
    if (args.length > 0) {
      jobId = parseDesignator(args[0])
      if (jobId === undefined) {
        return {
          exitCode: 1,
          stdout: '',
          stderr: `bg: ${args[0]}: no such job\n`,
          duration: performance.now() - start,
        }
      }
    }
    else {
      // Default to most recent stopped job
      const jobs = shell.getJobs()
      const stopped = jobs.filter(j => j.status === 'stopped')
      jobId = stopped.length ? stopped[stopped.length - 1].id : undefined
      if (jobId === undefined) {
        return {
          exitCode: 1,
          stdout: '',
          stderr: 'bg: no stopped jobs\n',
          duration: performance.now() - start,
        }
      }
    }

    if (shell.config.verbose)
      shell.log.debug('[bg] resuming job %d', jobId)

    // Find the job
    const job = shell.getJob(jobId)
    if (!job) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: `bg: job not found: ${jobId}\n`,
        duration: performance.now() - start,
      }
    }

    if (job.status !== 'stopped') {
      return {
        exitCode: 1,
        stdout: '',
        stderr: `bg: job ${jobId} is not stopped\n`,
        duration: performance.now() - start,
      }
    }

    // Resume the job in background using enhanced job control
    const success = shell.resumeJobBackground?.(jobId)
    if (success) {
      return {
        exitCode: 0,
        stdout: `[${jobId}] ${job.command} &\n`,
        stderr: '',
        duration: performance.now() - start,
      }
    }
    else {
      return {
        exitCode: 1,
        stdout: '',
        stderr: `bg: failed to resume job ${jobId}\n`,
        duration: performance.now() - start,
      }
    }
  },
}
