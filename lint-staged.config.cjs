const ruff = process.env.POETRY_ACTIVE ? 'poetry run ruff' : 'uvx ruff'
module.exports = {
  '*.py': (filenames) => filenames.map((filename) => `${ruff} check --output-format grouped "${filename}"`),
  '*.js': (filenames) => filenames.map((filename) => `pnpm eslint --no-color "${filename}"`)
}
