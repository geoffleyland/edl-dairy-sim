export async function fetchJSON<T>(url: string): Promise<T> {
  const response = await fetch(url)
  if (!response.ok) throw new Error(`GET ${url}: HTTP ${response.status}`)
  return response.json() as Promise<T>
}

export async function putJSON(url: string, body: unknown): Promise<void> {
  const response = await fetch(url, {
    method:  'PUT',
    headers: { 'Content-Type': 'application/json' },
    body:    JSON.stringify(body),
  })
  if (!response.ok) throw new Error(`PUT ${url}: HTTP ${response.status}`)
}

export async function postJSON<T>(url: string, body?: unknown): Promise<T> {
  const response = await fetch(url, {
    method:  'POST',
    headers: body !== undefined ? { 'Content-Type': 'application/json' } : undefined,
    body:    body !== undefined ? JSON.stringify(body) : undefined,
  })
  if (!response.ok) throw new Error(`POST ${url}: HTTP ${response.status}`)
  return response.json() as Promise<T>
}
