using 'main.bicep'

param environmentName = readEnvironmentVariable('AZURE_ENV_NAME', '')
param webAppName = readEnvironmentVariable('AZURE_WEBAPP_NAME', 'cloud-helper-fastmcp')
param existingPlanName = readEnvironmentVariable('EXISTING_PLAN_NAME', '')
