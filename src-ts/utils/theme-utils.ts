import { isBrowser } from './environment'

/**
 * Detects the user's preferred color scheme (light or dark)
 * @returns 'dark' if dark mode is preferred, 'light' otherwise
 */
export function detectPreferredColorScheme(): 'light' | 'dark' {
  if (!isBrowser)
    return 'dark' // Default to dark in non-browser environments

  // Check for localStorage preference first
  try {
    const savedTheme = window.localStorage?.getItem('krusty-theme')
    if (savedTheme === 'dark' || savedTheme === 'light') {
      return savedTheme
    }
  }
  catch {
    // Ignore errors
  }

  // Check system preference
  if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) {
    return 'dark'
  }

  return 'light'
}

/**
 * Sets up a listener for system color scheme changes
 * @param callback Function to call when the color scheme changes
 * @returns A function to remove the event listener
 */
export function onColorSchemeChange(callback: (isDark: boolean) => void): () => void {
  if (!isBrowser)
    return () => {}

  const mediaQuery = window.matchMedia('(prefers-color-scheme: dark)')
  const handler = (e: MediaQueryListEvent) => callback(e.matches)

  mediaQuery.addEventListener('change', handler)
  return () => mediaQuery.removeEventListener('change', handler)
}

/**
 * Gets the appropriate theme name based on the current color scheme
 * @param baseThemeName The base theme name (e.g., 'auto', 'auto-dark', 'auto-light')
 * @returns The resolved theme name
 */
export function resolveAutoTheme(baseThemeName: string): string {
  if (baseThemeName === 'auto') {
    return detectPreferredColorScheme() === 'dark' ? 'dark' : 'light'
  }
  if (baseThemeName === 'auto-dark') {
    return detectPreferredColorScheme() === 'dark' ? 'dark' : 'solarized-light'
  }
  if (baseThemeName === 'auto-light') {
    return detectPreferredColorScheme() === 'dark' ? 'solarized-dark' : 'light'
  }
  return baseThemeName
}
