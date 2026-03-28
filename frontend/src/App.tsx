import { useEffect, useState } from 'react'
import type { Task } from './types/task'
import { taskApi } from './api/tasks'
import './App.css'

type LoadingState = 'idle' | 'loading' | 'ready' | 'error'

function App() {
  const [tasks, setTasks] = useState<readonly Task[]>([])
  const [loadState, setLoadState] = useState<LoadingState>('idle')
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    setLoadState('loading')

    taskApi.list()
      .then((data) => {
        if (!cancelled) {
          setTasks(data)
          setLoadState('ready')
        }
      })
      .catch((err: unknown) => {
        if (!cancelled) {
          setError(err instanceof Error ? err.message : 'Failed to load tasks')
          setLoadState('error')
        }
      })

    return () => { cancelled = true }
  }, [])

  return (
    <main className="app">
      <header className="app-header">
        <h1 className="app-title">
          <span className="app-icon" aria-hidden="true">⚡</span>
          Mjolnir
        </h1>
        <p className="app-subtitle">Task management that strikes fast</p>
      </header>

      <section className="task-section" aria-label="Tasks">
        {loadState === 'loading' && (
          <div className="skeleton-list" role="status" aria-label="Loading tasks">
            {[1, 2, 3].map((i) => (
              <div key={i} className="skeleton-item" />
            ))}
          </div>
        )}

        {loadState === 'error' && (
          <div className="error-state" role="alert">
            <p className="error-message">{error}</p>
            <button
              className="retry-btn"
              onClick={() => window.location.reload()}
            >
              Retry
            </button>
          </div>
        )}

        {loadState === 'ready' && tasks.length === 0 && (
          <div className="empty-state">
            <span className="empty-icon" aria-hidden="true">🎯</span>
            <p className="empty-title">No tasks yet</p>
            <p className="empty-hint">Your task list is empty. Time to get productive!</p>
          </div>
        )}

        {loadState === 'ready' && tasks.length > 0 && (
          <ul className="task-list" role="list">
            {tasks.map((task) => (
              <li key={task.id} className={`task-item ${task.completed ? 'completed' : ''}`}>
                <span className="task-title">{task.title}</span>
                <span className="task-status">
                  {task.completed ? '✓' : '○'}
                </span>
              </li>
            ))}
          </ul>
        )}
      </section>
    </main>
  )
}

export default App
