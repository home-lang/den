import { isBrowser } from './environment'

/**
 * Loads a font from a URL and applies it to the document
 * @param fontFamily - The font family name to use
 * @param fontUrl - URL to the font file (supports .woff, .woff2, .ttf, .otf)
 * @param options - Font loading options
 * @param options.weights - Array of font weights to load (100-900)
 * @param options.display - Font display behavior (auto, block, swap, fallback, optional)
 * @param options.style - Font style (normal, italic)
 * @returns Promise that resolves when the font is loaded
 */
export async function loadFont(
  fontFamily: string,
  fontUrl: string,
  options: {
    weights?: (100 | 200 | 300 | 400 | 500 | 600 | 700 | 800 | 900)[]
    display?: 'auto' | 'block' | 'swap' | 'fallback' | 'optional'
    style?: 'normal' | 'italic'
  } = {},
): Promise<void> {
  if (!isBrowser)
    return Promise.resolve()

  const {
    weights = [400],
    display = 'swap',
    style = 'normal',
  } = options

  // Check if font is already loaded
  if (document.fonts) {
    const loaded = await document.fonts.ready
    // Use type assertion for FontFaceSet
    const fontFaceSet = loaded as unknown as FontFace[]
    const fontAvailable = fontFaceSet.some(
      (f: FontFace) => f.family === fontFamily,
    )
    if (fontAvailable) {
      return Promise.resolve()
    }
  }

  // Create a unique ID for the style element
  const styleId = `krusty-font-${fontFamily.toLowerCase().replace(/\s+/g, '-')}`

  // Check if style element already exists
  const existingStyle = document.getElementById(styleId)
  if (existingStyle) {
    return Promise.resolve()
  }

  return new Promise((resolve, reject) => {
    try {
      const fontFace = new FontFace(
        fontFamily,
        `url(${fontUrl})`,
        {
          weight: weights.join(' '),
          style,
          display,
        },
      )

      fontFace.load().then(
        () => {
          // Add the font to the document
          try {
            // Use type assertion for FontFaceSet
            const fonts = document.fonts as unknown as { add: (font: FontFace) => void }
            fonts.add(fontFace)

            // Create a style element to make the font available
            const styleEl = document.createElement('style')
            styleEl.id = styleId
            styleEl.textContent = `
              @font-face {
                font-family: '${fontFamily.replace(/'/g, '\'\'')}';
                src: url('${fontUrl}') format('${getFontFormat(fontUrl)}');
                font-display: ${display};
                font-weight: ${weights.join(' ')};
                font-style: ${style};
                ${style === 'italic' ? 'font-style: italic;' : ''}
              }
            `
            document.head.appendChild(styleEl)
            resolve()
          }
          catch (error) {
            console.warn('Error adding font:', error)
            resolve() // Still resolve to prevent unhandled rejection
          }
        },
        (err) => {
          console.warn(`Failed to load font ${fontFamily} from ${fontUrl}`, err)
          reject(err)
        },
      )
    }
    catch (error) {
      console.warn(`Error loading font ${fontFamily}:`, error)
      reject(error)
    }
  })
}

/**
 * Applies font settings to the terminal element
 * @param element - The terminal element to apply font settings to
 * @param font - Font configuration
 * @param font.family - Font family name
 * @param font.size - Font size in pixels
 * @param font.weight - Font weight (100-900 or normal/bold)
 * @param font.lineHeight - Line height as a multiplier
 * @param font.ligatures - Whether to enable ligatures
 */
export function applyFontSettings(
  element: HTMLElement,
  font: {
    family?: string
    size?: number
    weight?: string | number
    lineHeight?: number
    ligatures?: boolean
  },
): void {
  if (!isBrowser || !element)
    return

  const style = element.style

  if (font.family) {
    style.setProperty('--font-family', font.family)
    style.fontFamily = font.family
  }

  if (font.size) {
    style.setProperty('--font-size', `${font.size}px`)
    style.fontSize = `${font.size}px`
  }

  if (font.weight) {
    style.setProperty('--font-weight', String(font.weight))
    style.fontWeight = String(font.weight)
  }

  if (font.lineHeight) {
    style.setProperty('--line-height', String(font.lineHeight))
    style.lineHeight = String(font.lineHeight)
  }

  if (font.ligatures !== undefined) {
    style.setProperty('--font-feature-settings', font.ligatures ? '"liga" 1, "calt" 1' : 'normal')
    style.fontFeatureSettings = font.ligatures ? '"liga" 1, "calt" 1' : 'normal'
  }
}

/**
 * Gets the font format from the font URL
 * @param url - Font URL
 * @returns Font format string
 */
function getFontFormat(url: string): string {
  const ext = url.split('.').pop()?.toLowerCase()

  switch (ext) {
    case 'woff2':
      return 'woff2'
    case 'woff':
      return 'woff'
    case 'ttf':
      return 'truetype'
    case 'otf':
      return 'opentype'
    case 'eot':
      return 'embedded-opentype'
    case 'svg':
      return 'svg'
    default:
      return 'woff2' // Default to woff2
  }
}

/**
 * Loads Google Fonts
 * @param fontFamily - Google Font family name
 * @param options - Font loading options
 * @param options.weights - Array of font weights to load (100-900)
 * @param options.display - Font display behavior (auto, block, swap, fallback, optional)
 * @param options.subsets - Array of character subsets to load
 * @param options.text - Specific characters to load for subsetting
 * @returns Promise that resolves when the font is loaded
 */
export function loadGoogleFont(
  fontFamily: string,
  options: {
    weights?: (100 | 200 | 300 | 400 | 500 | 600 | 700 | 800 | 900)[]
    display?: 'auto' | 'block' | 'swap' | 'fallback' | 'optional'
    subsets?: string[]
    text?: string
  } = {},
): Promise<void> {
  if (!isBrowser)
    return Promise.resolve()

  const {
    weights = [400],
    display = 'swap',
    subsets = ['latin'],
    text,
  } = options

  // Create Google Fonts URL
  const family = fontFamily.replace(/\s+/g, '+')
  const weightsParam = `:wght@${weights.join(';')}`
  const displayParam = `&display=${display}`
  const subsetParam = subsets.length > 0 ? `&subset=${subsets.join(',')}` : ''
  const textParam = text ? `&text=${encodeURIComponent(text)}` : ''

  const url = `https://fonts.googleapis.com/css2?family=${family}${weightsParam}${displayParam}${subsetParam}${textParam}`

  // Create a link element to load the font
  const link = document.createElement('link')
  link.href = url
  link.rel = 'stylesheet'
  link.type = 'text/css'

  return new Promise((resolve, reject) => {
    link.onload = () => resolve()
    link.onerror = (err) => {
      console.warn(`Failed to load Google Font ${fontFamily}`, err)
      reject(err)
    }

    document.head.appendChild(link)
  })
}
