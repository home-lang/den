import type { BuiltinCommand, CommandResult, Shell } from './types'

export const waitCommand: BuiltinCommand = {
  name: 'wait',
  description: 'Wait for background jobs or PIDs to finish',
  usage: 'wait [job_id|pid]...',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()

    if (args.length === 0) {
      // Wait for all background jobs to complete
      const jobs = shell.getJobs().filter(job => job.status === 'running')

      if (jobs.length === 0) {
        return {
          exitCode: 0,
          stdout: '',
          stderr: '',
          duration: performance.now() - start,
        }
      }

      // Wait for all jobs using enhanced job control
      if (shell.waitForJob) {
        try {
          await Promise.all(jobs.map(job => shell.waitForJob!(job.id)))
          return {
            exitCode: 0,
            stdout: '',
            stderr: '',
            duration: performance.now() - start,
          }
        }
        catch (error) {
          return {
            exitCode: 1,
            stdout: '',
            stderr: `wait: error waiting for jobs: ${error}\n`,
            duration: performance.now() - start,
          }
        }
      }
    }

    // Wait for specific jobs/PIDs
    let exitCode = 0
    const errors: string[] = []

    for (const id of args) {
      if (id.startsWith('%')) {
        const jid = Number.parseInt(id.slice(1), 10)
        const job = shell.getJob(jid)
        if (!job) {
          exitCode = 1
          errors.push(`wait: ${id}: no current job`)
          continue
        }

        // Wait for specific job using enhanced job control
        if (shell.waitForJob && job.status !== 'done') {
          try {
            const completedJob = await shell.waitForJob(jid)
            if (completedJob && completedJob.exitCode !== 0) {
              exitCode = completedJob.exitCode
            }
          }
          catch (error) {
            exitCode = 1
            errors.push(`wait: ${id}: ${error}`)
          }
        }
      }
      else {
        const pid = Number.parseInt(id, 10)
        if (Number.isNaN(pid)) {
          exitCode = 1
          errors.push(`wait: ${id}: invalid id`)
          continue
        }

        // Find job by PID and wait for it
        const jobs = shell.getJobs()
        const job = jobs.find(j => j.pid === pid)
        if (job && shell.waitForJob && job.status !== 'done') {
          try {
            const completedJob = await shell.waitForJob(job.id)
            if (completedJob && completedJob.exitCode !== 0) {
              exitCode = completedJob.exitCode
            }
          }
          catch (error) {
            exitCode = 1
            errors.push(`wait: ${id}: ${error}`)
          }
        }
      }
    }

    return {
      exitCode,
      stdout: '',
      stderr: errors.length ? `${errors.join('\n')}\n` : '',
      duration: performance.now() - start,
    }
  },
}
