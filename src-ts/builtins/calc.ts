import type { BuiltinCommand, CommandResult } from './types'

export const calc: BuiltinCommand = {
  name: 'calc',
  description: 'Simple calculator with support for mathematical expressions',
  usage: 'calc [expression]',
  async execute(args, _shell): Promise<CommandResult> {
    const start = performance.now()

    if (args.includes('--help') || args.includes('-h')) {
      const helpText = `Usage: calc [expression]

Simple calculator with support for mathematical expressions.

Supported operations:
  +, -, *, /         Basic arithmetic
  ^, **              Exponentiation
  %, mod             Modulo
  sqrt(), cbrt()     Square root, cube root
  sin(), cos(), tan() Trigonometric functions (radians)
  log(), ln()        Logarithms (base 10 and natural)
  abs()              Absolute value
  round(), floor(), ceil() Rounding functions
  pi, e              Mathematical constants

Examples:
  calc "2 + 3 * 4"              Basic arithmetic
  calc "sqrt(16)"               Square root
  calc "sin(pi / 2)"            Trigonometry
  calc "2^10"                   Exponentiation
  calc "round(3.14159, 2)"      Rounding

Note: Use quotes for complex expressions to avoid shell interpretation.
`
      return {
        exitCode: 0,
        stdout: helpText,
        stderr: '',
        duration: performance.now() - start,
      }
    }

    if (args.length === 0) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: 'calc: missing expression\nUsage: calc [expression]\n',
        duration: performance.now() - start,
      }
    }

    const expression = args.join(' ')

    try {
      const result = evaluateExpression(expression)
      return {
        exitCode: 0,
        stdout: `${result}\n`,
        stderr: '',
        duration: performance.now() - start,
      }
    } catch (error) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: `calc: ${error.message}\n`,
        duration: performance.now() - start,
      }
    }
  },
}

function evaluateExpression(expr: string): number {
  // Clean up the expression
  let cleanExpr = expr.trim()

  // Replace mathematical constants
  cleanExpr = cleanExpr.replace(/\bpi\b/g, Math.PI.toString())
  cleanExpr = cleanExpr.replace(/\be\b/g, Math.E.toString())

  // Replace functions with Math equivalents
  const functions: Record<string, string> = {
    sqrt: 'Math.sqrt',
    cbrt: 'Math.cbrt',
    sin: 'Math.sin',
    cos: 'Math.cos',
    tan: 'Math.tan',
    log: 'Math.log10',
    ln: 'Math.log',
    abs: 'Math.abs',
    round: 'Math.round',
    floor: 'Math.floor',
    ceil: 'Math.ceil',
    min: 'Math.min',
    max: 'Math.max',
  }

  for (const [func, replacement] of Object.entries(functions)) {
    const regex = new RegExp(`\\b${func}\\b`, 'g')
    cleanExpr = cleanExpr.replace(regex, replacement)
  }

  // Replace exponentiation operators
  cleanExpr = cleanExpr.replace(/\^/g, '**')
  cleanExpr = cleanExpr.replace(/\bmod\b/g, '%')

  // Validate expression (basic safety check)
  if (!isValidExpression(cleanExpr)) {
    throw new Error('Invalid or unsafe expression')
  }

  try {
    // Use Function constructor for safe evaluation
    const result = new Function('Math', `return ${cleanExpr}`)(Math)

    if (typeof result !== 'number') {
      throw new Error('Expression did not evaluate to a number')
    }

    if (!isFinite(result)) {
      throw new Error('Result is not finite')
    }

    return result
  } catch (error) {
    throw new Error(`Evaluation failed: ${error.message}`)
  }
}

function isValidExpression(expr: string): boolean {
  // Basic safety checks to prevent code injection
  const allowedChars = /^[0-9+\-*/.()%\s,\w]+$/
  if (!allowedChars.test(expr)) {
    return false
  }

  // Check for dangerous patterns
  const dangerousPatterns = [
    /\beval\b/,
    /\bFunction\b/,
    /\brequire\b/,
    /\bimport\b/,
    /\bprocess\b/,
    /\bglobal\b/,
    /\bwindow\b/,
    /\bdocument\b/,
    /\bthis\b/,
    /\bwhile\b/,
    /\bfor\b/,
    /\bif\b/,
    /\breturn\b/,
    /\bvar\b/,
    /\blet\b/,
    /\bconst\b/,
    /\bclass\b/,
    /\bfunction\b/,
    /[{}[\]]/,
    /\.\./,
    /\/\*/,
    /\/\//,
  ]

  for (const pattern of dangerousPatterns) {
    if (pattern.test(expr)) {
      return false
    }
  }

  // Check balanced parentheses
  let depth = 0
  for (const char of expr) {
    if (char === '(') depth++
    if (char === ')') depth--
    if (depth < 0) return false
  }

  return depth === 0
}