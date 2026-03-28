/**
 * Minimal fetch wrapper with typed error handling.
 *
 * Every API call returns either the parsed JSON or throws an ApiError
 * with the status code and server message. This keeps error handling
 * consistent across all call sites.
 */

export class ApiError extends Error {
  readonly status: number
  readonly detail: string

  constructor(status: number, detail: string) {
    super(`API ${status}: ${detail}`)
    this.name = 'ApiError'
    this.status = status
    this.detail = detail
  }
}

interface RequestOptions {
  readonly method?: string
  readonly body?: unknown
  readonly headers?: Record<string, string>
}

async function request<T>(path: string, options: RequestOptions = {}): Promise<T> {
  const { method = 'GET', body, headers = {} } = options

  const config: RequestInit = {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...headers,
    },
  }

  if (body !== undefined) {
    config.body = JSON.stringify(body)
  }

  const response = await fetch(path, config)

  if (response.status === 204) {
    return undefined as T
  }

  const data: unknown = await response.json()

  if (!response.ok) {
    const detail = (data as { detail?: string })?.detail ?? response.statusText
    throw new ApiError(response.status, detail)
  }

  return data as T
}

export const api = {
  get: <T>(path: string) => request<T>(path),
  post: <T>(path: string, body: unknown) => request<T>(path, { method: 'POST', body }),
  put: <T>(path: string, body: unknown) => request<T>(path, { method: 'PUT', body }),
  delete: (path: string) => request<void>(path, { method: 'DELETE' }),
} as const
