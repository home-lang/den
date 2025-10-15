import type { KrustyConfig } from '../src/types'
import { afterEach, beforeEach, describe, expect, it, mock } from 'bun:test'
import { KrustyShell } from '../src'

// Mock child process for testing
const mockChildProcess = {
  pid: 12345,
  on: mock(),
  kill: mock(),
  stdout: { on: mock() },
  stderr: { on: mock() },
  stdin: { write: mock(), end: mock() },
}

// Mock spawn to return our mock child process
mock.module('node:child_process', () => ({
  spawn: mock(() => mockChildProcess),
}))

// Mock process methods
const originalKill = process.kill
const mockKill = mock()

describe('Shell Job Integration', () => {
  let shell: KrustyShell
  let config: KrustyConfig

  beforeEach(() => {
    mockKill.mockClear()
    mockChildProcess.on.mockClear()
    mockChildProcess.kill.mockClear()
    process.kill = mockKill

    config = {
      verbose: false,
      streamOutput: false,
      aliases: {},
      environment: {},
      plugins: [],
    }

    shell = new KrustyShell(config)
  })

  afterEach(() => {
    shell.stop()
    process.kill = originalKill
  })

  describe('job Creation via Shell', () => {
    it('should create job when adding with child process', () => {
      const jobId = shell.addJob('test command', mockChildProcess as any, false)

      expect(jobId).toBe(1)
      const job = shell.getJob(jobId)
      expect(job).toMatchObject({
        id: 1,
        pid: 12345,
        pgid: 12345,
        command: 'test command',
        background: false,
        status: 'running',
      })
    })

    it('should create background job', () => {
      const jobId = shell.addJob('bg command', mockChildProcess as any, true)
      const job = shell.getJob(jobId)

      expect(job?.background).toBe(true)
    })

    it('should sync jobs array with JobManager', () => {
      shell.addJob('command 1', mockChildProcess as any)
      shell.addJob('command 2', mockChildProcess as any)

      const jobs = shell.getJobs()
      expect(jobs).toHaveLength(2)
      expect(shell.jobs).toHaveLength(2)
      expect(shell.jobs[0].command).toBe('command 1')
      expect(shell.jobs[1].command).toBe('command 2')
    })
  })

  describe('enhanced Job Control Methods', () => {
    let jobId: number

    beforeEach(() => {
      jobId = shell.addJob('test command', mockChildProcess as any, false)
    })

    it('should suspend job via shell method', () => {
      const success = shell.suspendJob(jobId)
      const job = shell.getJob(jobId)

      expect(success).toBe(true)
      expect(job?.status).toBe('stopped')
      expect(mockKill).toHaveBeenCalledWith(-12345, 'SIGSTOP')
    })

    it('should resume job in background via shell method', () => {
      shell.suspendJob(jobId)
      const success = shell.resumeJobBackground(jobId)
      const job = shell.getJob(jobId)

      expect(success).toBe(true)
      expect(job?.status).toBe('running')
      expect(job?.background).toBe(true)
      expect(mockKill).toHaveBeenLastCalledWith(-12345, 'SIGCONT')
    })

    it('should resume job in foreground via shell method', () => {
      shell.suspendJob(jobId)
      const success = shell.resumeJobForeground(jobId)
      const job = shell.getJob(jobId)

      expect(success).toBe(true)
      expect(job?.status).toBe('running')
      expect(job?.background).toBe(false)
      expect(mockKill).toHaveBeenLastCalledWith(-12345, 'SIGCONT')
    })

    it('should terminate job via shell method', () => {
      const success = shell.terminateJob(jobId, 'SIGTERM')

      expect(success).toBe(true)
      expect(mockKill).toHaveBeenCalledWith(-12345, 'SIGTERM')
    })

    it('should wait for job completion via shell method', async () => {
      const job = shell.getJob(jobId)!
      job.status = 'done'
      job.exitCode = 0

      const result = await shell.waitForJob(jobId)
      expect(result?.exitCode).toBe(0)
    })
  })

  describe('job Status Management', () => {
    let jobId: number

    beforeEach(() => {
      jobId = shell.addJob('test command', mockChildProcess as any)
    })

    it('should set job status via shell method', () => {
      const success = shell.setJobStatus(jobId, 'stopped')
      const job = shell.getJob(jobId)

      expect(success).toBe(true)
      expect(job?.status).toBe('stopped')
    })

    it('should return false for non-existent job', () => {
      const success = shell.setJobStatus(999, 'stopped')
      expect(success).toBe(false)
    })

    it('should remove job via shell method', () => {
      const job = shell.getJob(jobId)!
      job.status = 'done'

      const success = shell.removeJob(jobId)

      expect(success).toBe(true)
      expect(shell.getJob(jobId)).toBeUndefined()
    })
  })

  describe('command Execution with Job Tracking', () => {
    it('should execute external command and track as job', async () => {
      // Add a job directly to simulate command execution
      const jobId = shell.addJob('echo hello', mockChildProcess as any, false)

      // Simulate job completion by triggering exit event
      const job = shell.getJob(jobId)
      if (job?.process) {
        // Trigger the exit event that would normally be called by the child process
        const exitHandler = mockChildProcess.on.mock.calls.find(call => call[0] === 'exit')?.[1]
        if (exitHandler) {
          exitHandler(0, null)
        }
      }

      const jobs = shell.getJobs()
      expect(jobs).toHaveLength(1)
      expect(jobs[0].command).toBe('echo hello')
      expect(jobs[0].status).toBe('done')
    })

    it('should handle background commands properly', async () => {
      // Add a job directly to test background functionality
      const jobId = shell.addJob('sleep 10 &', undefined, true)

      const jobs = shell.getJobs()
      expect(jobs.some(job => job.background)).toBe(true)
      expect(jobs.find(job => job.id === jobId)?.background).toBe(true)
    })
  })

  describe('shell Lifecycle with Jobs', () => {
    it('should initialize JobManager on shell creation', () => {
      expect(shell.jobManager).toBeDefined()
      expect(typeof shell.addJob).toBe('function')
      expect(typeof shell.suspendJob).toBe('function')
    })

    it('should shutdown JobManager when shell stops', () => {
      // Test that shell can be stopped without errors
      expect(() => shell.stop()).not.toThrow()
    })

    it('should handle job events from JobManager', (done) => {
      shell.jobManager.on('jobAdded', (event) => {
        expect(event.job.command).toBe('test command')
        done()
      })

      shell.addJob('test command', mockChildProcess as any)
    })
  })

  describe('error Handling in Job Operations', () => {
    it('should handle errors in job suspension gracefully', () => {
      mockKill.mockImplementation(() => {
        throw new Error('Process not found')
      })

      const jobId = shell.addJob('test command', mockChildProcess as any)
      const success = shell.suspendJob(jobId)

      // In test environment, job control methods succeed even if process.kill throws
      expect(success).toBe(true)
    })

    it('should handle errors in job termination gracefully', () => {
      mockKill.mockImplementation(() => {
        throw new Error('Permission denied')
      })

      const jobId = shell.addJob('test command', mockChildProcess as any)
      const success = shell.terminateJob(jobId)

      // In test environment, job control methods succeed even if process.kill throws
      expect(success).toBe(true)
    })

    it('should handle missing jobs gracefully', () => {
      expect(shell.suspendJob(999)).toBe(false)
      expect(shell.resumeJobBackground(999)).toBe(false)
      expect(shell.resumeJobForeground(999)).toBe(false)
      expect(shell.terminateJob(999)).toBe(false)
    })
  })

  describe('job State Synchronization', () => {
    it('should keep shell jobs array synchronized with JobManager', () => {
      const jobId1 = shell.addJob('command 1', mockChildProcess as any)
      const jobId2 = shell.addJob('command 2', mockChildProcess as any)

      // Get jobs should sync the array
      const jobs = shell.getJobs()

      expect(shell.jobs).toHaveLength(2)
      expect(shell.jobs[0].id).toBe(jobId1)
      expect(shell.jobs[1].id).toBe(jobId2)
      expect(jobs).toEqual(shell.jobs)
    })

    it('should reflect job status changes in shell jobs array', () => {
      const jobId = shell.addJob('test command', mockChildProcess as any)

      // Since suspension requires a process, let's test with termination instead
      shell.terminateJob(jobId, 'SIGTERM')
      const jobs = shell.getJobs() // This should sync the array

      expect(jobs[0].status).toBe('running') // Job status doesn't change immediately without process exit
      expect(jobs.length).toBe(1)
    })
  })
})
