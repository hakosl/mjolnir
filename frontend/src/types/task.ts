/**
 * Task domain types.
 *
 * These mirror the backend Pydantic models exactly — any drift between
 * frontend and backend types is a bug. Keeping them in a single file
 * makes it easy to compare with the Python models.
 */

/** The canonical task shape as returned by the API. */
export interface Task {
  readonly id: string
  readonly title: string
  readonly completed: boolean
  readonly position: number
  readonly created_at: string
  readonly updated_at: string
}

/** Payload for creating a new task. */
export interface TaskCreate {
  readonly title: string
}

/** Payload for updating an existing task. All fields optional. */
export interface TaskUpdate {
  readonly title?: string
  readonly completed?: boolean
}

/** Validation constants — must match backend TITLE_MIN/MAX_LENGTH. */
export const TITLE_MIN_LENGTH = 1
export const TITLE_MAX_LENGTH = 500
