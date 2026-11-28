#!/usr/bin/env bash
# =============================================================================
# Creates the Azure infrastructure for Sub2API with the Azure CLI:
#   - resource group
#   - (optional) Azure Container Registry, attached to the cluster
#   - hardened AKS cluster (Entra ID + Azure RBAC, no local accounts, Cilium
#     network policies, workload identity, automatic security upgrades)
#   - static public IP for the nginx load balancer
#   - (TLS_MODE=letsencrypt) managed identity that lets cert-manager solve
#     DNS-01 challenges in your Azure DNS zone
#
# Safe to re-run: existing resources are kept.
#
# Usage:  cd deploy/k8s && cp config.env.example config.env   # edit it
#         az login
#         ./azure/create-aks.sh
# =============================================================================
# shellcheck source=../scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"

need az
load_config

# ----------------------------------------------------------------- account ---
az account show >/dev/null 2>&1 || die "Not logged in. Run: az login"
if [[ -n "$AZ_SUBSCRIPTION_ID" ]]; then
    az account set --subscription "$AZ_SUBSCRIPTION_ID"
fi
SUBSCRIPTION_ID="$(azq account show --query id)"
log "Subscription : $(azq account show --query name) ($SUBSCRIPTION_ID)"
log "Resource grp : $AZ_RESOURCE_GROUP ($AZ_LOCATION)"
log "AKS cluster  : $AKS_CLUSTER_NAME  nodes $AKS_NODE_MIN-$AKS_NODE_MAX x $AKS_NODE_VM_SIZE"
[[ -n "$AKS_API_AUTHORIZED_IPS" ]] \
    || warn "AKS_API_AUTHORIZED_IPS is empty: the Kubernetes API server will accept connections from any IP."
confirm "Create / update these Azure resources?" || die "Aborted."

for ns in Microsoft.ContainerService Microsoft.Network Microsoft.Compute Microsoft.Storage Microsoft.ManagedIdentity; do
    if [[ "$(azq provider show --namespace "$ns" --query registrationState)" != "Registered" ]]; then
        log "Registering resource provider $ns"
        az provider register --namespace "$ns" --wait
    fi
done

# ---------------------------------------------------------- resource group ---
if [[ "$(azq group exists --name "$AZ_RESOURCE_GROUP")" == "true" ]]; then
    # A resource group's own location is only where its metadata is stored;
    # the resources inside it can live in any region (AZ_LOCATION).
    rg_location="$(azq group show --name "$AZ_RESOURCE_GROUP" --query location)"
    log "Resource group $AZ_RESOURCE_GROUP already exists (in $rg_location), reusing it"
else
    log "Creating resource group $AZ_RESOURCE_GROUP"
    az group create --name "$AZ_RESOURCE_GROUP" --location "$AZ_LOCATION" --tags app=sub2api -o none
fi

# --------------------------------------------------------------------- ACR ---
if [[ -n "$ACR_NAME" ]]; then
    if az acr show --name "$ACR_NAME" --resource-group "$AZ_RESOURCE_GROUP" >/dev/null 2>&1; then
        log "Container registry $ACR_NAME already exists"
    else
        log "Creating container registry $ACR_NAME"
        az acr create --name "$ACR_NAME" --resource-group "$AZ_RESOURCE_GROUP" \
            --location "$AZ_LOCATION" --sku Standard --admin-enabled false -o none
    fi
fi

# --------------------------------------------------------------------- AKS ---
if az aks show --name "$AKS_CLUSTER_NAME" --resource-group "$AZ_RESOURCE_GROUP" >/dev/null 2>&1; then
    aks_state="$(azq aks show --name "$AKS_CLUSTER_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query provisioningState)"
    [[ "$aks_state" == "Succeeded" ]] \
        || die "AKS cluster $AKS_CLUSTER_NAME exists but is in state '$aks_state' (a previous attempt failed half-way). Delete it and re-run:  az aks delete --name $AKS_CLUSTER_NAME --resource-group $AZ_RESOURCE_GROUP --yes"
    log "AKS cluster $AKS_CLUSTER_NAME already exists, skipping creation"
else
    # Which zones a VM size is offered in differs per region AND per subscription.
    # Keep only the requested zones this subscription can actually use.
    NODE_ZONES=""
    if [[ -n "$AKS_ZONES" ]]; then
        sku_filter="[?name=='$AKS_NODE_VM_SIZE'] | [0]"
        sku_name="$(azq vm list-skus --location "$AZ_LOCATION" --size "$AKS_NODE_VM_SIZE" \
            --resource-type virtualMachines --all --query "$sku_filter.name")"
        [[ -n "$sku_name" ]] || die "VM size $AKS_NODE_VM_SIZE does not exist in $AZ_LOCATION. Change AKS_NODE_VM_SIZE or AZ_LOCATION."
        sku_blocked="$(azq vm list-skus --location "$AZ_LOCATION" --size "$AKS_NODE_VM_SIZE" \
            --resource-type virtualMachines --all --query "$sku_filter.restrictions[?type=='Location'] | length(@)")"
        [[ "${sku_blocked:-0}" == "0" ]] \
            || die "VM size $AKS_NODE_VM_SIZE is not available to this subscription in $AZ_LOCATION. Change AKS_NODE_VM_SIZE or AZ_LOCATION."
        sku_zones="$(azq vm list-skus --location "$AZ_LOCATION" --size "$AKS_NODE_VM_SIZE" \
            --resource-type virtualMachines --all --query "$sku_filter.locationInfo[0].zones[]" | tr '\t\n' '  ')"
        sku_restricted="$(azq vm list-skus --location "$AZ_LOCATION" --size "$AKS_NODE_VM_SIZE" \
            --resource-type virtualMachines --all --query "$sku_filter.restrictions[?type=='Zone'].restrictionInfo.zones[]" | tr '\t\n' '  ')"
        for zone in $AKS_ZONES; do
            if [[ " $sku_zones " == *" $zone "* && " $sku_restricted " != *" $zone "* ]]; then
                NODE_ZONES+="${NODE_ZONES:+ }$zone"
            fi
        done
        if [[ -z "$NODE_ZONES" ]]; then
            warn "$AKS_NODE_VM_SIZE has no usable availability zone in $AZ_LOCATION for this subscription; creating nodes without zones."
        elif [[ "$NODE_ZONES" != "$AKS_ZONES" ]]; then
            warn "$AKS_NODE_VM_SIZE is only available in zone(s) '$NODE_ZONES' of $AZ_LOCATION for this subscription (requested '$AKS_ZONES')."
            warn "Nodes will use zone(s) '$NODE_ZONES'. For multi-zone resilience pick another AKS_NODE_VM_SIZE or AZ_LOCATION."
        fi
    fi

    log "Creating AKS cluster $AKS_CLUSTER_NAME (takes about 10 minutes)"
    aks_args=(
        --name "$AKS_CLUSTER_NAME"
        --resource-group "$AZ_RESOURCE_GROUP"
        --location "$AZ_LOCATION"
        --tier standard                       # financially backed API server SLA
        # --- nodes ---
        --nodepool-name default
        --node-vm-size "$AKS_NODE_VM_SIZE"
        --node-count "$AKS_NODE_MIN"
        --enable-cluster-autoscaler
        --min-count "$AKS_NODE_MIN"
        --max-count "$AKS_NODE_MAX"
        --os-sku AzureLinux
        --node-osdisk-size 128
        --no-ssh-key                          # no SSH access to nodes
        # --- network: Azure CNI Overlay + Cilium (enforces NetworkPolicy) ---
        --network-plugin azure
        --network-plugin-mode overlay
        --network-dataplane cilium
        --pod-cidr "$AKS_POD_CIDR"
        --load-balancer-sku standard
        # --- identity & access: Entra ID only, authorisation by Azure RBAC ---
        --enable-managed-identity
        --enable-aad
        --enable-azure-rbac
        --disable-local-accounts
        --enable-oidc-issuer
        --enable-workload-identity
        # --- keep it patched ---
        --auto-upgrade-channel patch
        --node-os-upgrade-channel NodeImage
        --enable-image-cleaner
        --image-cleaner-interval-hours 168
        --tags app=sub2api
    )
    if [[ -n "$NODE_ZONES" ]]; then
        # shellcheck disable=SC2206
        aks_args+=(--zones $NODE_ZONES)
    fi
    [[ -n "$AKS_KUBERNETES_VERSION" ]] && aks_args+=(--kubernetes-version "$AKS_KUBERNETES_VERSION")
    [[ -n "$AKS_API_AUTHORIZED_IPS" ]] && aks_args+=(--api-server-authorized-ip-ranges "$AKS_API_AUTHORIZED_IPS")
    [[ -n "$ACR_NAME" ]]               && aks_args+=(--attach-acr "$ACR_NAME")
    [[ "$AKS_ENABLE_DEFENDER" == "true" ]]   && aks_args+=(--enable-defender)
    [[ "$AKS_ENABLE_MONITORING" == "true" ]] && aks_args+=(--enable-addons monitoring)

    az aks create "${aks_args[@]}" -o none
fi

AKS_ID="$(azq aks show --name "$AKS_CLUSTER_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query id)"
NODE_RG="$(azq aks show --name "$AKS_CLUSTER_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query nodeResourceGroup)"
OIDC_ISSUER="$(azq aks show --name "$AKS_CLUSTER_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query oidcIssuerProfile.issuerUrl)"

# ------------------------------------------------------- cluster admin role ---
# Local accounts are disabled, so access is granted through Azure RBAC.
if ME="$(azq ad signed-in-user show --query id 2>/dev/null)" && [[ -n "$ME" ]]; then
    log "Granting 'Azure Kubernetes Service RBAC Cluster Admin' on the cluster to the signed-in user"
    az role assignment create --assignee-object-id "$ME" --assignee-principal-type User \
        --role "Azure Kubernetes Service RBAC Cluster Admin" --scope "$AKS_ID" -o none
else
    warn "Could not resolve the signed-in user (service principal login?). Assign the role"
    warn "'Azure Kubernetes Service RBAC Cluster Admin' on $AKS_ID to whoever deploys."
fi

# ---------------------------------------------------------------- public IP ---
if az network public-ip show --resource-group "$NODE_RG" --name "$PUBLIC_IP_NAME" >/dev/null 2>&1; then
    log "Public IP $PUBLIC_IP_NAME already exists"
else
    log "Creating static public IP $PUBLIC_IP_NAME in $NODE_RG"
    pip_args=(--resource-group "$NODE_RG" --name "$PUBLIC_IP_NAME" --location "$AZ_LOCATION"
              --sku Standard --allocation-method Static --tags app=sub2api)
    # Zone-redundant where the region has availability zones, plain otherwise.
    # shellcheck disable=SC2086
    if [[ -z "$AKS_ZONES" ]] || ! az network public-ip create "${pip_args[@]}" --zone $AKS_ZONES -o none 2>/dev/null; then
        [[ -z "$AKS_ZONES" ]] || warn "Could not create a zone-redundant public IP in $AZ_LOCATION; creating it without zones."
        az network public-ip create "${pip_args[@]}" -o none
    fi
fi
PUBLIC_IP="$(azq network public-ip show --resource-group "$NODE_RG" --name "$PUBLIC_IP_NAME" --query ipAddress)"

# ------------------------------------------- cert-manager identity (optional) ---
if [[ "$TLS_MODE" == "letsencrypt" ]]; then
    [[ -n "$DNS_ZONE_NAME" && -n "$DNS_ZONE_RESOURCE_GROUP" ]] \
        || die "TLS_MODE=letsencrypt needs DNS_ZONE_NAME and DNS_ZONE_RESOURCE_GROUP in config.env."
    DNS_ZONE_ID="$(azq network dns zone show --name "$DNS_ZONE_NAME" --resource-group "$DNS_ZONE_RESOURCE_GROUP" --query id)" \
        || die "Azure DNS zone $DNS_ZONE_NAME not found in $DNS_ZONE_RESOURCE_GROUP."

    log "Managed identity $CERT_MANAGER_IDENTITY_NAME for cert-manager (DNS-01)"
    az identity create --name "$CERT_MANAGER_IDENTITY_NAME" --resource-group "$AZ_RESOURCE_GROUP" \
        --location "$AZ_LOCATION" -o none
    CM_PRINCIPAL_ID="$(azq identity show --name "$CERT_MANAGER_IDENTITY_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query principalId)"

    # Scoped to the single DNS zone, nothing else.
    for attempt in 1 2 3 4 5 6; do
        if az role assignment create --assignee-object-id "$CM_PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
            --role "DNS Zone Contributor" --scope "$DNS_ZONE_ID" -o none 2>/dev/null; then
            break
        fi
        [[ "$attempt" == 6 ]] && die "Could not assign 'DNS Zone Contributor' on $DNS_ZONE_ID."
        sleep 10 # new identities take a moment to replicate
    done

    az identity federated-credential create --name cert-manager \
        --identity-name "$CERT_MANAGER_IDENTITY_NAME" --resource-group "$AZ_RESOURCE_GROUP" \
        --issuer "$OIDC_ISSUER" \
        --subject system:serviceaccount:cert-manager:cert-manager \
        --audiences api://AzureADTokenExchange -o none
fi

# -------------------------------------------------------------- kubeconfig ---
log "Fetching kubectl credentials"
az aks get-credentials --name "$AKS_CLUSTER_NAME" --resource-group "$AZ_RESOURCE_GROUP" --overwrite-existing
if command -v kubelogin >/dev/null 2>&1; then
    kubelogin convert-kubeconfig -l azurecli
else
    warn "kubelogin not found. Install kubectl + kubelogin with:  az aks install-cli"
    warn "then run:  kubelogin convert-kubeconfig -l azurecli"
fi

cat <<EOF

=============================================================================
 Azure infrastructure is ready.

   Cluster          : $AKS_CLUSTER_NAME  (resource group $AZ_RESOURCE_GROUP)
   Node resource grp: $NODE_RG
   Public IP        : $PUBLIC_IP

 Next steps
   1. Create a DNS A record:   ${DOMAIN:-<your domain>}  ->  $PUBLIC_IP
   2. Deploy the application:  ./scripts/deploy.sh
      (role assignments can take a few minutes to become effective; if
       kubectl answers "Forbidden", wait and retry)
=============================================================================
EOF
