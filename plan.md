# Todo App — Build Plan

## Product Vision

This is not just another todo list. It's a fast, offline-first task management app that feels native — snappy interactions, fluid drag-and-drop reordering, and zero lag whether you're on a plane or in a coffee shop. The app treats your tasks as first-class data: every edit, reorder, and deletion is captured locally and synced to the backend when connectivity returns, with conflict resolution that just works.

The frontend is a single-page React app built with Vite and TypeScript, designed around tactile micro-interactions — smooth drag animations, inline editing with instant feedback, and subtle state transitions that make task management feel effortless rather than bureaucratic. The backend is a lean FastAPI service backed by SQLite, chosen for its simplicity and zero-ops deployment story.

Offline mode is the architectural centerpiece, not an afterthought. A service worker intercepts all network requests, IndexedDB holds the local task graph, and a lightweight sync engine reconciles local mutations with the server using timestamp-based last-write-wins resolution. The result: the app loads instantly, works fully offline, and syncs transparently when the network returns.

## Technical Architecture

```
┌─────────────────────────────────────────────────┐
│                   Frontend (React + Vite + TS)   │
│                                                   │
│  ┌───────────┐  ┌────────────┐  ┌─────────────┐ │
│  │ TaskList   │  │ TaskEditor │  │ DragReorder │ │
│  │ Component  │  │ Component  │  │ Component   │ │
│  └─────┬─────┘  └─────┬──────┘  └──────┬──────┘ │
│        └───────────┬───┘────────────────┘        │
│              ┌─────▼──────┐                       │
│              │  Task Store │ (Zustand)            │
│              └─────┬──────┘                       │
│              ┌─────▼──────┐                       │
│              │ Sync Engine │                       │
│              └─────┬──────┘                       │
│        ┌───────────┼───────────┐                  │
│  ┌─────▼─────┐  ┌──▼───────┐  │                  │
│  │ IndexedDB  │  │ API Client│  │                  │
│  │ (offline)  │  │ (fetch)   │  │                  │
│  └────────────┘  └──┬───────┘  │                  │
│              ┌──────▼────────┐ │                  │
│              │Service Worker │ │                  │
│              └──────┬────────┘ │                  │
└─────────────────────┼──────────┘──────────────────┘
                      │ HTTP/REST
┌─────────────────────▼─────────────────────────────┐
│                Backend (FastAPI + Python 3.12+)    │
│                                                     │
│  ┌──────────┐  ┌───────────┐  ┌────────────────┐  │
│  │ Routes   │  │ Services  │  │ Repository     │  │
│  │ (CRUD +  │──▶ (business │──▶ (SQLite via    │  │
│  │  sync)   │  │  logic)   │  │  aiosqlite)    │  │
│  └──────────┘  └───────────┘  └────────────────┘  │
│                                                     │
│  ┌──────────────┐  ┌──────────────┐               │
│  │ Pydantic     │  │ Alembic      │               │
│  │ Models       │  │ Migrations   │               │
│  └──────────────┘  └──────────────┘               │
└─────────────────────────────────────────────────────┘
```

**Key architectural decisions:**
- **Zustand** for state management — minimal boilerplate, immutable updates by default, excellent TypeScript support
- **IndexedDB** (via idb) for offline storage — structured data, large capacity, async API
- **Service Worker** for network interception and cache-first strategy
- **aiosqlite** for async SQLite access on the backend — non-blocking I/O in FastAPI
- **Optimistic UI** everywhere — mutations apply locally first, sync in background
- **UUID-based IDs** generated client-side — enables offline creation without server round-trips

**Data Model:**
```
Task {
  id: UUID (client-generated)
  title: string (1-500 chars)
  completed: boolean
  position: float  // fractional indexing for O(1) reorder
  created_at: datetime
  updated_at: datetime
}
```

---

## Sprint 1: Project Skeleton & Core Backend

### Scope
- Initialize monorepo structure with frontend and backend directories
- Set up Vite + React + TypeScript frontend with strict tsconfig
- Set up FastAPI backend with SQLite database and async access
- Define the Task data model and database schema
- Implement basic CRUD API endpoints
- Add health check endpoint
- Configure CORS for local development
- Write initial tests for both frontend and backend

### Deliverables
- `frontend/` — Vite React TypeScript project with strict mode
- `frontend/src/types/task.ts` — Task type definitions
- `backend/` — FastAPI project with pyproject.toml
- `backend/app/main.py` — FastAPI app with CORS and lifespan
- `backend/app/models.py` — Pydantic models for Task
- `backend/app/repository.py` — SQLite repository with aiosqlite
- `backend/app/routes/tasks.py` — CRUD endpoints
- `backend/app/database.py` — Database connection and schema init
- `backend/tests/test_tasks.py` — API endpoint tests
- `README.md` — Setup and run instructions

### Acceptance Criteria
- Running `npm run dev` in `frontend/` starts the Vite dev server on port 5173
- Running `uvicorn app.main:app` in `backend/` starts the API on port 8000
- `GET /health` returns `{"status": "ok"}`
- `POST /api/tasks` with `{"title": "Buy milk"}` returns 201 with a JSON body containing `id`, `title`, `completed`, `position`, `created_at`, `updated_at`
- `GET /api/tasks` returns 200 with a JSON array of all tasks ordered by `position`
- `PUT /api/tasks/{id}` updates a task and returns the updated task
- `DELETE /api/tasks/{id}` returns 204
- `POST /api/tasks` with empty title returns 422 with validation error
- `POST /api/tasks` with title exceeding 500 characters returns 422
- All task IDs are UUIDs
- Backend tests pass with `pytest` and cover all CRUD operations
- TypeScript compiles with zero errors in strict mode

### Technical Notes
- Use `uuid4` for IDs generated server-side (will switch to client-generated in Sprint 5)
- SQLite schema: `tasks(id TEXT PRIMARY KEY, title TEXT NOT NULL, completed BOOLEAN DEFAULT FALSE, position REAL NOT NULL, created_at TEXT, updated_at TEXT)`
- Use `REAL` for position to allow fractional repositioning without reindexing
- New tasks get `position = max(position) + 1.0`
- Set up `ruff` for Python linting and `eslint` + `prettier` for TypeScript
- Use `httpx.AsyncClient` for backend tests (FastAPI test client)
- Use `aiosqlite` for async SQLite access

---

## Sprint 2: Task List UI & Basic Interactions

### Scope
- Build the main TaskList component that displays all tasks
- Implement "Add Task" with inline input at the top
- Implement task completion toggle with checkbox
- Implement inline task title editing (click to edit)
- Implement task deletion with confirmation
- Connect frontend to backend API
- Add loading and empty states

### Deliverables
- `frontend/src/components/TaskList.tsx` — Main task list container
- `frontend/src/components/TaskItem.tsx` — Individual task row
- `frontend/src/components/TaskInput.tsx` — New task input field
- `frontend/src/components/EmptyState.tsx` — Empty state illustration
- `frontend/src/hooks/useTasks.ts` — Data fetching and mutation hook
- `frontend/src/api/client.ts` — API client wrapper
- `frontend/src/api/tasks.ts` — Task-specific API functions
- `frontend/src/styles/` — CSS modules or Tailwind styles
- `frontend/src/__tests__/TaskList.test.tsx` — Component tests

### Acceptance Criteria
- App displays a list of tasks fetched from the backend API
- User can type a task title and press Enter to add it — the new task appears immediately at the top of the list
- User can click a checkbox to toggle a task's completed state — completed tasks show strikethrough text
- User can double-click a task title to enter edit mode, modify the text, and press Enter to save or Escape to cancel
- User can click a delete button on a task — a confirmation appears, and confirming removes the task
- When no tasks exist, a friendly empty state message is displayed (not a blank screen)
- A loading spinner or skeleton is shown while tasks are being fetched
- All interactions persist to the backend (refresh the page and changes are still there)
- Input validation: the add field does not allow submitting an empty or whitespace-only title
- Frontend tests cover add, toggle, edit, and delete flows

### Technical Notes
- Use Zustand store for task state management — keep API calls in the hook layer, not in components
- Debounce title edits (300ms) to avoid excessive API calls during typing
- Use optimistic updates: apply change to local state immediately, then sync to backend
- CSS: consider Tailwind CSS for rapid styling, or CSS modules for scoped styles
- Use `React.memo` on TaskItem to avoid re-rendering the entire list on single-item changes
- Keep components small and focused — each under 100 lines

---

## Sprint 3: Drag-and-Drop Reordering

### Scope
- Implement drag-and-drop task reordering with smooth animations
- Add reorder API endpoint on the backend
- Persist new order to the database using fractional indexing
- Visual feedback during drag (elevation, shadow, placeholder)
- Keyboard-accessible reordering (Alt+Up/Down)

### Deliverables
- `frontend/src/components/DraggableTaskList.tsx` — Drag-and-drop wrapper
- `frontend/src/components/DragHandle.tsx` — Grab handle icon
- `frontend/src/hooks/useReorder.ts` — Reorder logic and API sync
- `frontend/src/utils/fractionalIndex.ts` — Utility for calculating positions between items
- `backend/app/routes/tasks.py` — `PATCH /api/tasks/{id}/reorder` endpoint
- `frontend/src/__tests__/DraggableTaskList.test.tsx` — Drag interaction tests
- `backend/tests/test_reorder.py` — Reorder endpoint tests

### Acceptance Criteria
- User can grab a task by its drag handle and move it to a new position — the list reorders smoothly with animation
- While dragging, the dragged item is visually elevated (shadow/scale) and a placeholder shows where it will drop
- After dropping, the new order persists — refreshing the page shows the same order
- `PATCH /api/tasks/{id}/reorder` accepts `{"after_id": "<uuid>"}` (or `null` for first position) and returns 200 with updated task
- Reordering between two adjacent items does not require re-indexing all items (fractional positioning)
- User can press Alt+ArrowUp or Alt+ArrowDown to move the focused task up or down
- Dragging is touch-friendly on mobile viewports
- Reordering 100 items does not visibly lag (O(1) position calculation)
- Reorder persists correctly even after adding new tasks

### Technical Notes
- Use `@dnd-kit/core` and `@dnd-kit/sortable` — best React DnD library for accessibility and mobile
- Fractional positioning: when moving between items at position 1.0 and 2.0, assign position 1.5
- After many reorders, positions may get very close; implement periodic rebalancing when gap < 0.0001
- Use `requestAnimationFrame` for smooth drag animations
- Backend reorder endpoint calculates position as midpoint of neighbors
- DnD Kit's `useSortable` gives `transform` and `transition` for smooth animations

---

## Sprint 4: Polish, Animations & Visual Design

### Scope
- Design a cohesive visual identity — color palette, typography, spacing
- Add micro-animations for all state transitions (add, complete, delete, reorder)
- Implement responsive layout (mobile-first)
- Add keyboard shortcuts for power users
- Dark mode support with system preference detection
- Task count and filter bar (All / Active / Completed)

### Deliverables
- `frontend/src/styles/theme.ts` — Design tokens (colors, spacing, typography)
- `frontend/src/styles/global.css` — Global styles and CSS custom properties
- `frontend/src/components/FilterBar.tsx` — All/Active/Completed filter
- `frontend/src/components/TaskCount.tsx` — "3 tasks remaining" counter
- `frontend/src/hooks/useKeyboardShortcuts.ts` — Global keyboard shortcuts
- `frontend/src/hooks/useTheme.ts` — Dark/light mode toggle with system preference detection
- `frontend/src/components/ThemeToggle.tsx` — Dark/light mode switch
- `frontend/src/components/KeyboardShortcutsHelp.tsx` — Shortcut help modal
- Updated component styles across all existing components

### Acceptance Criteria
- Adding a task triggers a slide-in animation from the top
- Completing a task triggers a satisfying checkmark animation and the text fades to strikethrough
- Deleting a task triggers a slide-out animation before removal
- Reordering has spring-physics animation (not linear)
- Filter bar shows "All (5)", "Active (3)", "Completed (2)" with correct counts
- Clicking a filter shows only matching tasks — URL updates to reflect filter (e.g., `?filter=active`)
- Dark mode toggle works and respects `prefers-color-scheme` system setting
- Dark mode preference persists in localStorage
- App looks good on mobile (375px), tablet (768px), and desktop (1280px+)
- Keyboard shortcuts: `n` to focus new task input, `?` to show shortcut help, `d` to toggle dark mode
- All interactive elements have visible focus indicators for keyboard navigation
- Color contrast meets WCAG AA standards (4.5:1 for normal text)
- No layout shift or jank during any animation
- Animations respect `prefers-reduced-motion` media query

### Technical Notes
- Use `framer-motion` for animations — `AnimatePresence` for enter/exit, `layout` prop for reorder
- CSS custom properties for theming — toggle a `data-theme` attribute on `<html>`
- Use `matchMedia('(prefers-color-scheme: dark)')` for system preference detection
- Filter state in URL via `useSearchParams`
- Keep animations under 300ms for responsiveness
- Keyboard shortcut handler should not fire when user is typing in an input
- Consider a subtle gradient or pattern background to elevate above "plain white page"

---

## Sprint 5: Offline Storage with IndexedDB

### Scope
- Set up IndexedDB as the local task store
- Implement read/write operations for tasks in IndexedDB
- Make the app functional without a backend connection
- Queue mutations when offline for later sync
- Show online/offline status indicator
- Switch to client-generated UUIDs for offline creation

### Deliverables
- `frontend/src/db/index.ts` — IndexedDB setup and schema (using `idb` library)
- `frontend/src/db/tasks.ts` — Task CRUD operations against IndexedDB
- `frontend/src/sync/queue.ts` — Mutation queue for offline changes
- `frontend/src/sync/types.ts` — Sync operation type definitions
- `frontend/src/components/ConnectionStatus.tsx` — Online/offline indicator
- `frontend/src/hooks/useOnlineStatus.ts` — Network status hook
- `frontend/src/__tests__/db.test.ts` — IndexedDB operation tests
- `frontend/src/__tests__/queue.test.ts` — Mutation queue tests

### Acceptance Criteria
- All tasks are stored in IndexedDB in addition to being fetched from the API
- When the network is unavailable, the app loads tasks from IndexedDB and is fully functional
- User can add, edit, complete, delete, and reorder tasks while offline — all changes are stored locally
- Tasks created offline use client-generated UUIDs (no server round-trip needed)
- A small indicator shows "Offline" when disconnected and "Online" when connected
- Mutations made offline are queued in IndexedDB with timestamp and operation type
- The mutation queue persists across browser refreshes (stored in IndexedDB, not memory)
- When coming back online, a "Syncing..." indicator briefly appears
- IndexedDB data survives browser restart
- IndexedDB tests verify CRUD operations work correctly
- No console errors appear when operating offline

### Technical Notes
- Use the `idb` library — thin Promise wrapper over IndexedDB
- Database schema: `tasks` object store (keyed by `id`) + `syncQueue` object store (auto-increment key)
- Queue entries: `{ id, operation: 'create'|'update'|'delete'|'reorder', payload, timestamp }`
- Use `navigator.onLine` + `online`/`offline` events for status detection
- Zustand store should read from IndexedDB on init, then keep in-memory state in sync
- Switch ID generation to `crypto.randomUUID()` on the client side

---

## Sprint 6: Service Worker & Cache Strategy

### Scope
- Register a service worker for offline asset caching
- Implement cache-first strategy for static assets
- Implement network-first strategy for API requests with IndexedDB fallback
- Enable app to load instantly from cache on repeat visits
- Add PWA manifest for installability

### Deliverables
- `frontend/src/sw.ts` — Service worker with caching strategies
- `frontend/src/sw-register.ts` — Service worker registration
- `frontend/public/manifest.json` — PWA manifest
- `frontend/public/icons/` — App icons (192px, 512px)
- `frontend/vite.config.ts` — Updated with PWA plugin config
- `frontend/src/__tests__/sw.test.ts` — Service worker strategy tests

### Acceptance Criteria
- After first visit, the app loads fully from cache when offline (no "dinosaur" page)
- Static assets (JS, CSS, HTML) use cache-first strategy — instant load on repeat visits
- API requests attempt network first, fall back to cached responses
- Service worker updates transparently — user sees a "New version available, refresh" toast when an update is ready
- PWA manifest enables "Add to Home Screen" on mobile browsers
- App icon appears correctly when installed as PWA
- Service worker does not interfere with hot module replacement in development
- `navigator.serviceWorker.ready` resolves successfully in production build
- Refreshing the page while offline still loads the app shell and displays cached tasks

### Technical Notes
- Use `vite-plugin-pwa` with `injectManifest` strategy for custom service worker logic
- Cache names should include a version hash for cache busting
- Precache the app shell (index.html, main JS/CSS bundles)
- Runtime cache API responses with a short TTL (5 min) as fallback
- Skip service worker registration in development (`import.meta.env.DEV`)
- Generate icons from a single SVG source

---

## Sprint 7: Sync Engine & Conflict Resolution

### Scope
- Build the sync engine that reconciles offline mutations with the server
- Implement last-write-wins conflict resolution using timestamps
- Add a server-side sync endpoint that accepts batched mutations
- Handle edge cases: deleted-on-server, modified-on-both, created-offline
- Add sync status per task (synced / pending / conflict)
- Retry with exponential backoff

### Deliverables
- `frontend/src/sync/engine.ts` — Core sync engine
- `frontend/src/sync/resolver.ts` — Conflict resolution logic
- `frontend/src/sync/status.ts` — Per-task sync status tracking
- `frontend/src/components/SyncStatus.tsx` — Visual sync status (per-task indicator)
- `backend/app/routes/sync.py` — `POST /api/sync` batch endpoint
- `backend/app/services/sync.py` — Server-side sync logic
- `backend/tests/test_sync.py` — Sync endpoint tests with conflict scenarios
- `frontend/src/__tests__/engine.test.ts` — Sync engine unit tests
- `frontend/src/__tests__/resolver.test.ts` — Conflict resolution tests

### Acceptance Criteria
- When coming online after offline edits, all queued mutations are sent to the server in order
- `POST /api/sync` accepts `{"mutations": [{"op": "create"|"update"|"delete", "task": {...}, "timestamp": "..."}]}` and returns `{"applied": [...], "conflicts": [...]}`
- Last-write-wins: if both client and server modified the same task, the newer timestamp wins
- If a task was deleted on the server but edited offline, the edit is discarded and the task disappears locally
- Tasks created offline sync to the server and receive proper server acknowledgment
- Each task shows a subtle sync indicator: checkmark (synced), spinner (pending), or warning (conflict)
- During sync, a progress indicator shows "Syncing N changes..."
- After successful sync, a brief "All changes synced" confirmation appears for 3 seconds
- Sync engine retries failed syncs with exponential backoff (1s, 2s, 4s, max 30s)
- After sync, client and server data are consistent
- Sync tests cover: normal sync, create-offline, edit-conflict, delete-conflict, network-failure-retry

### Technical Notes
- Use `updated_at` timestamps for conflict detection — client sends its last-known `updated_at`
- Server compares client's `updated_at` with current — if different, it's a conflict
- Batch mutations to minimize round-trips — send all queued ops in one request
- Exponential backoff with jitter to avoid thundering herd on reconnect
- After queue drain, do a full data reconciliation: `GET /api/tasks?since={last_sync_timestamp}`
- Consider a "sync log" in IndexedDB for debugging sync issues

---

## Sprint 8: Error Handling, Edge Cases & Resilience

### Scope
- Comprehensive error handling across all user flows
- Toast notification system for user feedback
- Handle all edge cases: rapid clicks, concurrent edits, empty titles, very long titles
- Input validation on both frontend and backend
- Rate limiting on backend endpoints
- Graceful degradation when backend is unreachable
- Search and bulk operations

### Deliverables
- `frontend/src/components/Toast.tsx` — Toast notification component
- `frontend/src/hooks/useToast.ts` — Toast state management
- `frontend/src/utils/validation.ts` — Input validation utilities
- `frontend/src/components/SearchBar.tsx` — Search input with debounced filtering
- `frontend/src/components/BulkActions.tsx` — Mark all complete, clear completed
- `frontend/src/components/ErrorBoundary.tsx` — React error boundary with fallback UI
- `backend/app/middleware/rate_limit.py` — Rate limiting middleware
- `backend/app/middleware/error_handler.py` — Global error handler
- `frontend/src/__tests__/validation.test.ts` — Validation tests
- `backend/tests/test_validation.py` — Backend validation tests

### Acceptance Criteria
- Empty task title shows inline error "Title cannot be empty" — the task is not created
- Task title over 500 characters shows inline error "Title must be under 500 characters"
- Backend returns 422 with structured error body for invalid input
- Backend returns 429 when rate limit exceeded (100 requests/minute per IP)
- Network errors show a toast: "Changes saved locally. Will sync when online."
- Server errors (500) show a toast: "Something went wrong. Please try again."
- Rapid-clicking the complete checkbox doesn't cause race conditions or inconsistent state
- Double-submitting a new task (pressing Enter twice quickly) creates only one task
- Deleting a task while it's being edited doesn't cause errors
- All error toasts auto-dismiss after 5 seconds and can be manually dismissed
- Search input filters tasks in real-time as user types (debounced 200ms, case-insensitive)
- "Mark all complete" and "Clear completed" bulk actions work correctly
- Backend error responses follow consistent format: `{"detail": "message", "code": "ERROR_CODE"}`
- Error boundary catches React crashes and shows "Something went wrong" with retry button

### Technical Notes
- Use a debounce/throttle on mutation triggers to prevent rapid-fire issues
- Backend rate limiter: use `slowapi` or a simple in-memory token bucket
- Toast system: use a Zustand store with auto-dismiss timers, max 3 visible toasts
- Validation: share max-length constants between frontend and backend
- Test error scenarios by mocking failed API responses in frontend tests
- Search: client-side filtering of Zustand store for instant response

---

## Sprint 9: Performance Optimization & Accessibility

### Scope
- Optimize bundle size and loading performance
- Virtualize long task lists (1000+ items)
- Implement proper ARIA attributes and screen reader support
- Keyboard navigation for all interactions
- Add focus management and skip links
- Optimize re-renders and memory usage

### Deliverables
- `frontend/src/components/VirtualTaskList.tsx` — Virtualized list for large datasets
- Updated ARIA attributes across all components
- `frontend/src/components/SkipLink.tsx` — Skip to main content link
- `frontend/src/hooks/useFocusManagement.ts` — Focus trap and restoration
- Lighthouse reports (performance, accessibility, PWA)
- `frontend/src/__tests__/a11y.test.tsx` — Accessibility tests

### Acceptance Criteria
- Lighthouse Performance score >= 90 on mobile throttling
- Lighthouse Accessibility score >= 95
- App handles 1000+ tasks without jank — scrolling remains smooth (60fps)
- All interactive elements are reachable via Tab key in logical order
- Screen reader announces: task title, completion status, position in list
- Drag-and-drop has screen reader announcements: "Grabbed task. Use arrow keys to reorder. Press Space to drop."
- Skip link appears on Tab and jumps to main task list
- Bundle size < 200KB gzipped for initial load
- No unnecessary re-renders when a single task changes (verified via React DevTools profiler)
- Images/icons use proper alt text or aria-hidden
- `aria-live` regions announce: new task added, task completed, task deleted, sync status changes

### Technical Notes
- Use `@tanstack/react-virtual` for list virtualization
- Use `react-aria` or manual ARIA for drag-and-drop accessibility
- Code-split: lazy-load settings/theme panel and keyboard shortcuts help
- Tree-shake unused Framer Motion features
- Use `React.memo`, `useMemo`, `useCallback` judiciously (profile first, optimize second)
- Run `npx vite-bundle-analyzer` to identify large dependencies

---

## Sprint 10: End-to-End Testing & Production Readiness

### Scope
- Comprehensive E2E test suite covering all critical user flows
- Production build configuration and deployment readiness
- Final visual polish pass
- Documentation for setup, development, and deployment
- Backend production configuration (logging, CORS, security headers)

### Deliverables
- `e2e/` — Playwright E2E test suite
- `e2e/tests/task-crud.spec.ts` — Create, read, update, delete flows
- `e2e/tests/reorder.spec.ts` — Drag-and-drop reorder flow
- `e2e/tests/offline.spec.ts` — Offline mode flow
- `e2e/tests/sync.spec.ts` — Sync after offline edits
- `e2e/tests/a11y.spec.ts` — Accessibility checks via axe
- `docker-compose.yml` — Full stack in Docker for easy deployment
- `Dockerfile.frontend` — Frontend production build
- `Dockerfile.backend` — Backend production image
- `README.md` — Comprehensive project documentation

### Acceptance Criteria
- E2E: User can add a task, edit its title, mark it complete, reorder it, and delete it — all in one test flow
- E2E: User can go offline, make changes, come back online, and see changes synced
- E2E: Drag-and-drop reorder works and persists after page refresh
- E2E: App loads from cache when offline (service worker test)
- E2E: Accessibility audit passes with zero critical violations (axe-core)
- `docker-compose up` starts both frontend and backend, accessible at `localhost:3000`
- Production frontend build has no TypeScript errors, no console warnings
- Backend runs with proper logging (structured JSON logs), security headers (HSTS, X-Frame-Options), and CORS locked to frontend origin
- README includes: project overview, tech stack, setup instructions, development commands, architecture diagram, deployment guide
- All tests (unit + integration + E2E) pass in CI-like conditions
- Backend test coverage >= 80%, frontend test coverage >= 80%
- No console errors or warnings in the production build
- Smoke test passes: add 5 tasks, reorder them, complete 2, delete 1, go offline, add 2 more, come back online, verify all data is consistent

### Technical Notes
- Use Playwright for E2E — excellent offline/service worker testing support
- Test offline by using `context.setOffline(true)` in Playwright
- Use `@axe-core/playwright` for accessibility testing
- Docker: multi-stage builds to minimize image size
- Backend production: use `gunicorn` with `uvicorn` workers
- Frontend production: Vite build with chunk splitting and preload hints
- In production, FastAPI can serve the built frontend via `StaticFiles` mount
- Set `Cache-Control` headers: immutable for hashed assets, no-cache for HTML
- Consider a `Makefile` for common dev commands
