import type { ChildProcess } from 'node:child_process'
import type { KrustyConfig } from '../src/types'
import { afterEach, beforeEach, describe, expect, it, mock } from 'bun:test'
import { KrustyShell } from '../src'
import { JobManager } from '../src/jobs/job-manager'

// Simple mock child process
function createMockChildProcess(pid: number = 12345): Partial<ChildProcess> {
  return {
    pid,
    on: mock(),
    kill: mock(),
    stdout: { on: mock() } as any,
    stderr: { on: mock() } as any,
    stdin: { write: mock(), end: mock() } as any,
  }
}

describe('Job Control Integration', () => {
  let jobManager: JobManager
  let shell: KrustyShell
  let mockChildProcess: Partial<ChildProcess>
  let originalKill: typeof process.kill

  beforeEach(() => {
    originalKill = process.kill
    process.kill = mock()

    jobManager = new JobManager()
    mockChildProcess = createMockChildProcess()

    const config: KrustyConfig = {
      verbose: false,
      streamOutput: false,
      aliases: {},
      environment: {},
      plugins: [],
    }
    shell = new KrustyShell(config)
  })

  afterEach(() => {
    jobManager.shutdown()
    shell.stop()
    process.kill = originalKill
  })

  describe('JobManager Core Functionality', () => {
    it('should add and track jobs', () => {
      const jobId = jobManager.addJob('test command', mockChildProcess as ChildProcess, false)

      expect(jobId).toBe(1)
      const job = jobManager.getJob(jobId)
      expect(job).toBeDefined()
      expect(job?.command).toBe('test command')
      expect(job?.pid).toBe(12345)
      expect(job?.status).toBe('running')
    })

    it('should suspend running jobs', () => {
      const jobId = jobManager.addJob('vim file.txt', mockChildProcess as ChildProcess, false)

      const success = jobManager.suspendJob(jobId)

      expect(success).toBe(true)
      const job = jobManager.getJob(jobId)
      expect(job?.status).toBe('stopped')
    })

    it('should resume jobs in background', () => {
      const jobId = jobManager.addJob('vim file.txt', mockChildProcess as ChildProcess, false)
      jobManager.suspendJob(jobId)

      const success = jobManager.resumeJobBackground(jobId)

      expect(success).toBe(true)
      const job = jobManager.getJob(jobId)
      expect(job?.status).toBe('running')
      expect(job?.background).toBe(true)
    })

    it('should resume jobs in foreground', () => {
      const jobId = jobManager.addJob('vim file.txt', mockChildProcess as ChildProcess, false)
      jobManager.suspendJob(jobId)

      const success = jobManager.resumeJobForeground(jobId)

      expect(success).toBe(true)
      const job = jobManager.getJob(jobId)
      expect(job?.status).toBe('running')
      expect(job?.background).toBe(false)
    })

    it('should terminate jobs', () => {
      const jobId = jobManager.addJob('sleep 100', mockChildProcess as ChildProcess, false)

      const success = jobManager.terminateJob(jobId)

      expect(success).toBe(true)
    })

    it('should track foreground job', () => {
      const jobId = jobManager.addJob('vim file.txt', mockChildProcess as ChildProcess, false)

      expect(jobManager.getForegroundJob()?.id).toBe(jobId)
    })

    it('should handle job removal', () => {
      const jobId = jobManager.addJob('echo done', mockChildProcess as ChildProcess, false)
      const job = jobManager.getJob(jobId)!
      job.status = 'done'

      const success = jobManager.removeJob(jobId)

      expect(success).toBe(true)
      expect(jobManager.getJob(jobId)).toBeUndefined()
    })
  })

  describe('Shell Integration', () => {
    it('should delegate job operations to JobManager', () => {
      const jobId = shell.addJob('test command', mockChildProcess as ChildProcess, false)

      expect(jobId).toBe(1)
      const job = shell.getJob(jobId)
      expect(job?.command).toBe('test command')
    })

    it('should suspend jobs via shell', () => {
      const jobId = shell.addJob('vim file.txt', mockChildProcess as ChildProcess, false)

      const success = shell.suspendJob(jobId)

      expect(success).toBe(true)
      expect(shell.getJob(jobId)?.status).toBe('stopped')
    })

    it('should resume jobs via shell', () => {
      const jobId = shell.addJob('vim file.txt', mockChildProcess as ChildProcess, false)
      shell.suspendJob(jobId)

      const success = shell.resumeJobBackground(jobId)

      expect(success).toBe(true)
      expect(shell.getJob(jobId)?.status).toBe('running')
    })

    it('should terminate jobs via shell', () => {
      const jobId = shell.addJob('sleep 100', mockChildProcess as ChildProcess, false)

      const success = shell.terminateJob(jobId)

      expect(success).toBe(true)
    })

    it('should sync jobs array with JobManager', () => {
      shell.addJob('command 1', mockChildProcess as ChildProcess)
      shell.addJob('command 2', createMockChildProcess(12346) as ChildProcess)

      const jobs = shell.getJobs()
      expect(jobs).toHaveLength(2)
      expect(shell.jobs).toHaveLength(2)
    })
  })

  describe('Error Handling', () => {
    it('should handle non-existent jobs gracefully', () => {
      expect(jobManager.suspendJob(999)).toBe(false)
      expect(jobManager.resumeJobBackground(999)).toBe(false)
      expect(jobManager.terminateJob(999)).toBe(false)
      expect(jobManager.removeJob(999)).toBe(false)
    })

    it('should handle invalid job states', () => {
      const jobId = jobManager.addJob('echo done', mockChildProcess as ChildProcess, false)
      const job = jobManager.getJob(jobId)!
      job.status = 'done'

      expect(jobManager.suspendJob(jobId)).toBe(false)
      expect(jobManager.resumeJobBackground(jobId)).toBe(false)
    })

    it('should handle signal errors gracefully', () => {
      const mockKill = process.kill as any
      mockKill.mockImplementation(() => {
        throw new Error('No such process')
      })

      const jobId = jobManager.addJob('sleep 100', mockChildProcess as ChildProcess, false)
      const success = jobManager.suspendJob(jobId)

      // In test environment, job control methods succeed even if process.kill throws
      expect(success).toBe(true)
    })
  })

  describe('Job Events', () => {
    it('should emit job events', (done) => {
      jobManager.on('jobAdded', (event) => {
        expect(event.job.command).toBe('test command')
        done()
      })

      jobManager.addJob('test command', mockChildProcess as ChildProcess, false)
    })

    it('should emit suspension events', (done) => {
      const jobId = jobManager.addJob('vim file.txt', mockChildProcess as ChildProcess, false)

      jobManager.on('jobSuspended', (event) => {
        expect(event.job.id).toBe(jobId)
        done()
      })

      setTimeout(() => {
        jobManager.suspendJob(jobId)
      }, 10)
    })

    it('should emit resume events', (done) => {
      const jobId = jobManager.addJob('vim file.txt', mockChildProcess as ChildProcess, false)
      jobManager.suspendJob(jobId)

      jobManager.on('jobResumed', (event) => {
        expect(event.job.id).toBe(jobId)
        done()
      })

      jobManager.resumeJobBackground(jobId)
    })
  })

  describe('Background vs Foreground Jobs', () => {
    it('should handle background jobs correctly', () => {
      const jobId = jobManager.addJob('sleep 100', mockChildProcess as ChildProcess, true)
      const job = jobManager.getJob(jobId)!

      expect(job.background).toBe(true)
      expect(jobManager.getForegroundJob()).toBeUndefined()
    })

    it('should handle foreground jobs correctly', () => {
      const jobId = jobManager.addJob('vim file.txt', mockChildProcess as ChildProcess, false)
      const job = jobManager.getJob(jobId)!

      expect(job.background).toBe(false)
      expect(jobManager.getForegroundJob()?.id).toBe(jobId)
    })

    it('should transition jobs between foreground and background', () => {
      const jobId = jobManager.addJob('vim file.txt', mockChildProcess as ChildProcess, false)

      // Suspend and resume in background
      jobManager.suspendJob(jobId)
      jobManager.resumeJobBackground(jobId)

      const job = jobManager.getJob(jobId)!
      expect(job.background).toBe(true)
      expect(jobManager.getForegroundJob()).toBeUndefined()

      // Resume in foreground
      jobManager.suspendJob(jobId)
      jobManager.resumeJobForeground(jobId)

      // Get updated job reference since job objects are replaced on status changes
      const updatedJob = jobManager.getJob(jobId)!
      expect(updatedJob.background).toBe(false)
      expect(jobManager.getForegroundJob()?.id).toBe(jobId)
    })
  })
})
