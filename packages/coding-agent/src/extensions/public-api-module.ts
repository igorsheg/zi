export const extensionApiModuleSource = `
const make = (type, options = {}) => Object.freeze({ ...options, type })
const optionalKey = "~optional"

export const Schema = Object.freeze({
  string: options => make("string", options),
  number: options => make("number", options),
  integer: options => make("integer", options),
  boolean: options => make("boolean", options),
  literal: value => Object.freeze({ const: value }),
  array: (items, options = {}) => Object.freeze({ ...options, type: "array", items }),
  optional: value => Object.freeze({ ...value, [optionalKey]: true }),
  object: (properties, options = {}) => {
    const admitted = {}
    const required = []
    for (const [name, value] of Object.entries(properties)) {
      const { [optionalKey]: optional, ...property } = value
      admitted[name] = Object.freeze(property)
      if (!optional) required.push(name)
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
