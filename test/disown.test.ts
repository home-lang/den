import type { KrustyConfig } from '../src/types'
import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

describe('disown builtin command', () => {
  let shell: KrustyShell
  let testConfig: KrustyConfig

  beforeEach(() => {
    testConfig = {
      ...defaultConfig,
      verbose: false,
      history: {
        ...defaultConfig.history,
        file: `/tmp/test_history_disown_${Math.random().toString(36).slice(2)}`,
      },
    }
    shell = new KrustyShell(testConfig)
  })

  afterEach(() => {
    shell.stop()
  })

  it('returns success when no jobs exist', async () => {
    const res = await shell.execute('disown')
    expect(res.exitCode).toBe(0)
    expect(res.stderr).toBe('')
  })

  it('disowns the most recent job when no args are given', async () => {
    // Create mock child processes with PIDs
    const mockChild1 = { pid: 12345, on: () => {}, removeAllListeners: () => {} } as any
    const mockChild2 = { pid: 23456, on: () => {}, removeAllListeners: () => {} } as any

    const j1 = shell.addJob('sleep 1', mockChild1)
    const j2 = shell.addJob('sleep 2', mockChild2)
    expect(j1).toBe(1)
    expect(j2).toBe(2)

    const res = await shell.execute('disown')
    expect(res.exitCode).toBe(0)

    // Job 2 should be removed; job 1 should still exist
    const jobs = shell.getJobs()
    const ids = jobs.map(j => j.id)
    expect(ids).toContain(1)
    expect(ids).not.toContain(2)
  })

  it('supports %N format for job IDs', async () => {
    const mockChild1 = { pid: 34567, on: () => {}, removeAllListeners: () => {} } as any
    const j1 = shell.addJob('sleep 1', mockChild1)
    expect(j1).toBe(1)

    const res = await shell.execute('disown %1')
    expect(res.exitCode).toBe(0)

    const jobs = shell.getJobs()
    expect(jobs.length).toBe(0)
  })

  it('reports error for invalid job IDs when jobs exist', async () => {
    const mockChild1 = { pid: 45678, on: () => {}, removeAllListeners: () => {} } as any
    shell.addJob('sleep 1', mockChild1)

    const res = await shell.execute('disown %999')
    expect(res.exitCode).toBe(1)
    expect(res.stderr).toContain('disown: 999: no such job')
    expect(res.stderr.endsWith('\n')).toBe(true)
  })

  it('handles multiple job IDs', async () => {
    const mockChild1 = { pid: 11111, on: () => {}, removeAllListeners: () => {} } as any
    const mockChild2 = { pid: 22222, on: () => {}, removeAllListeners: () => {} } as any
    shell.addJob('sleep 1', mockChild1) // id 1
    shell.addJob('sleep 2', mockChild2) // id 2

    const res = await shell.execute('disown 1 2')
    expect(res.exitCode).toBe(0)

    const jobs = shell.getJobs()
    expect(jobs.length).toBe(0)
  })

  it('reports pid-less jobs as errors', async () => {
    // Create a mock child process with a valid PID
    const mockProcess = {
      pid: 33333,
      on: () => {},
      kill: () => {},
      unref: () => {},
      ref: () => {},
      removeListener: () => {},
      removeAllListeners: () => {},
      addListener: () => {},
      once: () => {},
      off: () => {},
      listeners: () => [],
      setMaxListeners: () => {},
      getMaxListeners: () => 0,
      emit: () => false,
      prependListener: () => {},
      prependOnceListener: () => {},
      eventNames: () => [],
      listenerCount: () => 0,
      rawListeners: () => [],
    }

    // Add the job with the mock process
    const id = shell.jobManager.addJob('sleep 1', mockProcess as any, false)

    // Get the job and modify it to be pid-less
    const job = shell.getJob(id)
    if (job) {
      // Force the job to be pid-less by directly manipulating the job manager's internal state
      const jobs = (shell.jobManager as any).jobs as Map<number, any>
      const jobEntry = Array.from(jobs.entries()).find(([_, j]) => j.id === id)
      if (jobEntry) {
        const [jobId, jobData] = jobEntry
        const pidLessJob = { ...jobData, pid: undefined as unknown as number }
        jobs.set(jobId, pidLessJob)
      }
    }

    const res = await shell.execute(`disown ${id}`)
    expect(res.exitCode).toBe(1)
    expect(res.stderr).toContain(`disown: ${id}: job has no pid`)
    expect(res.stderr.endsWith('\n')).toBe(true)

    // Ensure the job remains since it couldn't be removed
    const jobs = shell.getJobs()
    expect(jobs.find(j => j.id === id)).toBeDefined()
  })
})
