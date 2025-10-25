import type { BuiltinCommand, CommandResult, Shell } from './types'

/**
 * Fg command - bring a background job to the foreground
 * Resumes a stopped job or brings a background job to the foreground
 */
export const fgCommand: BuiltinCommand = {
  name: 'fg',
  description: 'Bring a background job to the foreground',
  usage: 'fg [job_id]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()
    // Get all jobs
    const jobs = shell.getJobs()

    if (jobs.length === 0) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: 'fg: no current job\n',
        duration: performance.now() - start,
      }
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

    let jobId: number | undefined
    if (args.length === 0) {
      const live = jobs.filter(j => j.status !== 'done')
      jobId = live.length ? live[live.length - 1].id : undefined
    }
    else {
      jobId = parseDesignator(args[0])
    }
    if (jobId === undefined) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: 'fg: no current job\n',
        duration: performance.now() - start,
      }
    }
    if (shell.config.verbose)
      shell.log.debug('[fg] parsed jobId=%s', String(jobId))

    // Find the job
    const job = shell.getJob(jobId)
    if (!job) {
      if (shell.config.verbose)
        shell.log.debug('[fg] job not found: %d', jobId)
      return {
        exitCode: 1,
        stdout: '',
        stderr: `fg: ${jobId}: no such job\n`,
        duration: performance.now() - start,
      }
    }

    // Allow stopped jobs or already-running background jobs
    if (!(job.status === 'stopped' || (job.status === 'running' && job.background))) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: `fg: job ${jobId} is not stoppable or attachable\n`,
        duration: performance.now() - start,
      }
    }

    // Resume the job in foreground using enhanced job control
    const success = shell.resumeJobForeground?.(jobId)
    if (success) {
      if (shell.config.verbose)
        shell.log.debug('[fg] set job %d to running (foreground)', jobId)

      // Wait for the job to complete if waitForJob is available
      if (shell.waitForJob) {
        try {
          const completedJob = await shell.waitForJob(jobId)
          if (completedJob) {
            return {
              exitCode: completedJob.exitCode || 0,
              stdout: `${job.command}\n`,
              stderr: '',
              duration: performance.now() - start,
            }
          }
        }
        catch (error) {
          return {
            exitCode: 1,
            stdout: '',
            stderr: `fg: error waiting for job ${jobId}: ${error}\n`,
            duration: performance.now() - start,
          }
        }
      }

      const res: CommandResult = {
        exitCode: 0,
        stdout: `${job.command}\n`,
        stderr: '',
        duration: performance.now() - start,
      }
      if (shell.config.verbose)
        shell.log.debug('[fg] done in %dms', Math.round(res.duration || 0))
      return res
    }
    else {
      return {
        exitCode: 1,
        stdout: '',
        stderr: `fg: failed to resume job ${jobId}\n`,
        duration: performance.now() - start,
      }
    }
  },
}
