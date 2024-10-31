# New-AzureApp.ps1
# -----------------
# Author: kyle@latitudes.io
# Date: 2024-10-31
# Script to create a new Azure Enterprise Application with API permissions and an app secret using only Microsoft.Graph

# Variables
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$AppName = "NewEnterpriseApp-$Timestamp"
$RedirectUri = "https://localhost"  
$Domain = "latitudes.io" # Must be a verified domain in your tenant
$SecretExpiryMonths = 24

# Define permissions to be assigned to the new application
$Permissions = @( 
    @{ ScopeName = "User.Read.All" },
    @{ ScopeName = "Directory.ReadWrite.All" }
)

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
    Write-Host "Microsoft Graph module not found. Installing Microsoft Graph module..."
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        Write-Host "Installing NuGet package provider..."
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
    }
    Install-Module -Name Microsoft.Graph -AllowClobber -Scope CurrentUser -Force
}

try {
    # Connect to Microsoft Graph with required scopes
    Write-Host "Connecting to Microsoft Graph..."
    Connect-MgGraph -Scopes @(
        "Application.ReadWrite.All",
        "Directory.ReadWrite.All",
        "Directory.Read.All",
        "AppRoleAssignment.ReadWrite.All",
        "ServicePrincipalEndpoint.ReadWrite.All"
    ) -NoWelcome -ErrorAction Stop -UseDeviceCode
    
    $TenantId = (Get-MgOrganization -ErrorAction Stop).Id

    # Retrieve Microsoft Graph Service Principal
    Write-Host "Retrieving Microsoft Graph Service Principal..."
    $MicrosoftGraphServicePrincipal = Get-MgServicePrincipal -Filter "displayName eq 'Microsoft Graph'" -ConsistencyLevel eventual -ErrorAction Stop

    if ($null -eq $MicrosoftGraphServicePrincipal) {
        throw "Could not find Microsoft Graph Service Principal"
    }
    Write-Host "Microsoft Graph Service Principal ID: $($MicrosoftGraphServicePrincipal.Id)"
    
    # Create new Azure AD application
    Write-Host "Creating new Azure AD Application with name: $AppName"
    function CreateAzureADApplication {
        try {
            $Application = New-MgApplication -DisplayName $AppName -IdentifierUris "https://$AppName.$Domain" -Web @{ RedirectUris = @($RedirectUri) } -ErrorAction Stop
           
            if ($null -eq $Application) {
                throw "Failed to create Azure AD Application"
            }
            
            return $Application
        }
        catch {
            if ($_.Exception.Message -match "HostNameNotOnVerifiedDomain") {
                Write-Error "Error: The specified domain '$Domain' is not verified in your tenant. Please select a verified domain."
                
                try {
                    $domains = Get-MgDomain -ErrorAction Stop
                    Write-Host "`nVerified Domains in your tenant:" -ForegroundColor Yellow
                    $domains | Where-Object IsVerified -eq $true | Format-Table Id, IsVerified -AutoSize
                }
                catch {
                    Write-Warning "Could not retrieve domain list: $_"
                }
                
                Write-Host "Please retry the script with one of the verified domains listed above." -ForegroundColor Yellow
                exit 1  # Exit here instead of throwing
            }
            else {
                Write-Error "An unexpected error occurred: $_"
                exit 1
            }
        }
    }

    $Application = CreateAzureADApplication
    Write-Host "Application created successfully:"
    Write-Host "Application ID (AppId): $($Application.AppId)"
    Write-Host "Application ObjectId: $($Application.Id)"
    # Store the Application information
    $AppId = $Application.AppId
    $ObjectId = $Application.Id
    
    # Create Service Principal for the application
    Write-Host "Creating Service Principal for Application ID: $AppId"
    $ServicePrincipal = New-MgServicePrincipal -AppId $AppId -ErrorAction Stop
    if ($null -eq $ServicePrincipal) {
        throw "Failed to create the Service Principal."
    }
    Write-Host "Service Principal ID: $($ServicePrincipal.Id)"
    
    # Wait a few seconds for service principal propagation
    Start-Sleep -Seconds 5
    
    # Assign API Permissions using Microsoft Graph
    foreach ($permission in $Permissions) {
        Write-Host "Assigning permission: $($permission.ScopeName) to Service Principal..."
        
        try {
            $params = @{
                ClientId     = $ServicePrincipal.Id
                ConsentType  = "AllPrincipals"
                ResourceId   = $MicrosoftGraphServicePrincipal.Id
                Scope        = $permission.ScopeName
            }
            
            Write-Host "Attempting to grant permission: $($permission.ScopeName)"
            New-MgOAuth2PermissionGrant @params -ErrorAction Stop
            Write-Host "Successfully assigned permission: $($permission.ScopeName)"
        }
        catch {
            if ($_.Exception.Message -match "Permission entry already exists" -or $_.Exception.Message -match "Request_MultipleObjectsWithSameKeyValue") {
                Write-Host "Permission $($permission.ScopeName) already assigned (this is OK)" -ForegroundColor Green
            }
            else {
                Write-Warning "Unexpected error while assigning permission $($permission.ScopeName): $_"
            }
        }
    }
    
    # Grant admin consent for the permissions
    Write-Host "Granting admin consent for the assigned permissions..."
    $requiredResourceAccess = @(
        @{
            ResourceAppId   = $MicrosoftGraphServicePrincipal.AppId
            ResourceAccess  = @()
        }
    )
    
    foreach ($permission in $Permissions) {
        try {
            # Get the permission ID from Microsoft Graph Service Principal
            $permissionId = $MicrosoftGraphServicePrincipal.Oauth2PermissionScopes | 
                Where-Object { $_.Value -eq $permission.ScopeName } |
                Select-Object -ExpandProperty Id
    
            if ($null -eq $permissionId) {
                Write-Warning "Could not find permission ID for scope: $($permission.ScopeName)"
                continue
            }
    
            # Add to the required resource access array
            $requiredResourceAccess[0].ResourceAccess += @{
                Id   = $permissionId
                Type = "Scope"
            }
            
            Write-Host "Added permission: $($permission.ScopeName) to required resource access"
        }
        catch {
            Write-Warning "Failed to process permission $($permission.ScopeName): $_"
            continue
        }
    }
    
    # Update the application with all permissions at once
    try {
        Write-Host "Updating application with ObjectId: $ObjectId"
        
        if ([string]::IsNullOrEmpty($ObjectId)) {
            throw "Application ObjectId is empty"
        }
    
        # Function to get application with retry
        function Get-MgApplicationWithRetry {
            param (
                [string]$AppId,
                [int]$MaxAttempts = 5,
                [int]$DelaySeconds = 5
            )
            
            for ($i = 1; $i -le $MaxAttempts; $i++) {
                Write-Host "Attempt $i of $MaxAttempts to retrieve application..."
                $mgApplication = Get-MgApplication -Filter "appId eq '$AppId'" -ErrorAction SilentlyContinue
                
                if ($null -ne $mgApplication) {
                    Write-Host "Successfully retrieved application on attempt $i"
                    return $mgApplication
                }
                
                if ($i -lt $MaxAttempts) {
                    Write-Host "Application not found, waiting $DelaySeconds seconds before retry..."
                    Start-Sleep -Seconds $DelaySeconds
                }
            }
            
            throw "Could not find application after $MaxAttempts attempts"
        }
    
        # Get fresh application object from Microsoft Graph with retry
        $mgApplication = Get-MgApplicationWithRetry -AppId $AppId
        Write-Host "Found application in Microsoft Graph. ID: $($mgApplication.Id)"
    
        $updateParams = @{
            RequiredResourceAccess = $requiredResourceAccess
        }
        
        Update-MgApplication -ApplicationId $mgApplication.Id -BodyParameter $updateParams -ErrorAction Stop
        Write-Host "Updated application with all required resource access permissions"
    
        # Wait for changes to propagate
        Write-Host "Waiting for changes to propagate..."
        Start-Sleep -Seconds 10
    }
    catch {
        Write-Warning "Failed to update application permissions: $_"
        Write-Host "Application ObjectId: $ObjectId"
        Write-Host "Application AppId: $AppId"
        # Continue execution as this is not critical
    }
    
    Write-Host "Admin consent granted. Ensure to review and approve the permissions in the Azure Portal if necessary."
    
    # Generate new application secret
    Write-Host "Generating new application secret..."
    try {
        if ([string]::IsNullOrEmpty($ObjectId)) {
            throw "Application ObjectId is empty"
        }
    
        $endDate = (Get-Date).AddMonths($SecretExpiryMonths)
        Write-Host "Creating secret for Application ObjectId: $ObjectId"
        $NewSecret = Add-MgApplicationPassword -ApplicationId $ObjectId -PasswordCredential @{
            DisplayName = "ClientSecret-$Timestamp"
            EndDateTime = $endDate
        } -ErrorAction Stop
        
        if ($null -eq $NewSecret) {
            throw "Failed to generate secret"
        }

        Write-Host "----------------------------------------"
        Write-Host "Application Name: $AppName"
        Write-Host "Identifier URI: https://$AppName.$Domain"
        Write-Host "Tenant ID: $TenantId"
        Write-Host "ApplicationId: $AppId"
        Write-Host "Client Secret Value: $($NewSecret.SecretText)"
        Write-Host "** IMPORTANT: Store this client secret securely. It will not be displayed again. **"
        Write-Host "----------------------------------------"
    }
    catch {
        Write-Error "Failed to generate application secret: $_"
        throw
    }
    
}
catch {
    if ($_ -match "HostNameNotOnVerifiedDomain") {
        # Specific error already handled in CreateAzureADApplication
        Write-Host "Please retry the script with a verified domain."
    }
    else {
        Write-Error "An error occurred: $_"
    }
    exit 1
}