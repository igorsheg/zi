export const extensionApiModuleSource = `
const optionalKey = "~optional"
const make = (type, options = {}) => Object.freeze({ ...options, type })
const primitiveType = value => {
  if (value === null) return "null"
  switch (typeof value) {
    case "string": return "string"
    case "number": return "number"
    case "boolean": return "boolean"
    default: throw new Error("Literal values must be JSON primitives")
  }
}

export const Schema = Object.freeze({
  string: options => make("string", options),
  number: options => make("number", options),
  integer: options => make("integer", options),
  boolean: options => make("boolean", options),
  literal: (value, options = {}) => Object.freeze({
    ...options,
    type: primitiveType(value),
    const: value
  }),
  array: (items, options = {}) => Object.freeze({ ...options, type: "array", items }),
  optional: schema => Object.freeze({ ...schema, [optionalKey]: true }),
  object: (properties, options = {}) => {
    const admitted = {}
    const required = []
    for (const [name, schema] of Object.entries(properties)) {
      const { [optionalKey]: isOptional, ...property } = schema
      admitted[name] = Object.freeze(property)
      if (!isOptional) required.push(name)
    }
    return Object.freeze({
      ...options,
      type: "object",
      properties: Object.freeze(admitted),
      ...(required.length > 0 ? { required: Object.freeze(required) } : {})
    })
  }
})
`
