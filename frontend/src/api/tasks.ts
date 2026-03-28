/**
 * Task API functions — thin wrappers around the generic API client.
 *
 * Each function maps 1:1 to a backend endpoint. No business logic here,
 * just type-safe HTTP calls.
 */

import type { Task, TaskCreate, TaskUpdate } from '../types/task'
import { api } from './client'

const BASE = '/api/tasks'

export const taskApi = {
  list: () => api.get<Task[]>(BASE),

  get: (id: string) => api.get<Task>(`${BASE}/${id}`),

  create: (payload: TaskCreate) => api.post<Task>(BASE, payload),

  update: (id: string, payload: TaskUpdate) => api.put<Task>(`${BASE}/${id}`, payload),

  delete: (id: string) => api.delete(`${BASE}/${id}`),
} as const
