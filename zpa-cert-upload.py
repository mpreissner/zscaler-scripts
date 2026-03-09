#!/usr/bin/env python3
import requests
import json
import sys
import time
import os
from pathlib import Path
from datetime import datetime

# ZPA OneAPI Configuration - matching Postman collection variables
ZIDENTITY_BASE_URL = os.environ.get('ZIDENTITY_BASE_URL')
ONEAPI_BASE_URL = os.environ.get('ONEAPI_BASE_URL', 'https://api.zsapi.net')
ZPA_CLIENT_ID = os.environ.get('ZPA_CLIENT_ID')
ZPA_CLIENT_SECRET = os.environ.get('ZPA_CLIENT_SECRET')
ZPA_CUSTOMER_ID = os.environ.get('ZPA_CUSTOMER_ID')

if not all([ZIDENTITY_BASE_URL, ZPA_CLIENT_ID, ZPA_CLIENT_SECRET, ZPA_CUSTOMER_ID]):
    print("ERROR: Required environment variables must be set:")
    print("  - ZIDENTITY_BASE_URL")
    print("  - ZPA_CLIENT_ID")
    print("  - ZPA_CLIENT_SECRET")
    print("  - ZPA_CUSTOMER_ID")
    sys.exit(1)

# Certificate paths (passed from acme.sh)
CERT_PATH = sys.argv[1] if len(sys.argv) > 1 else None
KEY_PATH = sys.argv[2] if len(sys.argv) > 2 else None
DOMAIN = sys.argv[3] if len(sys.argv) > 3 else None

# Optional: Log file
LOG_FILE = "/var/log/zpa-cert-upload.log"

class ZPAOneAPIClient:
    def __init__(self, zidentity_url, oneapi_url, client_id, client_secret, customer_id):
        self.zidentity_url = zidentity_url.rstrip('/')
        self.oneapi_url = oneapi_url.rstrip('/')
        self.client_id = client_id
        self.client_secret = client_secret
        self.customer_id = customer_id
        self.token_url = f"{self.zidentity_url}/oauth2/v1/token"
        self.base_url = f"{self.oneapi_url}/zpa/mgmtconfig/v1/admin/customers/{customer_id}"
        self.access_token = None
        self.token_expiry = 0
        
    def _log(self, message):
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        log_msg = f"[{timestamp}] {message}"
        print(log_msg)
        try:
            with open(LOG_FILE, 'a') as f:
                f.write(log_msg + "\n")
        except:
            pass
    
    def _get_access_token(self):
        """Exchange client credentials for access token (OAuth2 client_credentials flow)"""
        if self.access_token and time.time() < self.token_expiry:
            return self.access_token
        
        self._log("Obtaining access token from ZIdentity...")
        
        headers = {
            "Content-Type": "application/x-www-form-urlencoded"
        }
        
        data = {
            "grant_type": "client_credentials",
            "client_id": self.client_id,
            "client_secret": self.client_secret,
            "audience": "https://api.zscaler.com"
        }
        
        response = requests.post(self.token_url, headers=headers, data=data)
        
        if response.status_code == 200:
            token_data = response.json()
            self.access_token = token_data['access_token']
            expires_in = token_data.get('expires_in', 3600)
            self.token_expiry = time.time() + (expires_in * 0.9)
            self._log(f"✓ Access token obtained (expires in {expires_in}s)")
            return self.access_token
        else:
            self._log(f"✗ Failed to obtain access token: {response.status_code} - {response.text}")
            response.raise_for_status()
    
    def _get_headers(self):
        token = self._get_access_token()
        return {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "*/*"
        }
    
    def upload_certificate(self, cert_path, key_path, name, description=""):
        """Upload certificate to ZPA"""
        self._log(f"Reading certificate files...")
        
        with open(cert_path, 'r') as f:
            cert_data = f.read().strip()
        with open(key_path, 'r') as f:
            key_data = f.read().strip()
        
        combined_pem = cert_data + "\n" + key_data
        
        url = f"{self.base_url}/certificate"
        payload = {
            "name": name,
            "description": description,
            "certBlob": combined_pem
        }
        
        self._log(f"Uploading certificate: {name}")
        self._log(f"  Combined PEM size: {len(combined_pem)} bytes")
        
        response = requests.post(url, headers=self._get_headers(), json=payload)
        
        if response.status_code in [200, 201]:
            cert_response = response.json()
            self._log(f"✓ Certificate uploaded successfully (ID: {cert_response['id']})")
            return cert_response
        else:
            self._log(f"✗ Certificate upload failed: {response.status_code} - {response.text}")
            response.raise_for_status()
    
    def get_certificates(self, page=1, page_size=500):
        """List all certificates"""
        url = f"{self.base_url}/certificate"
        params = {"page": page, "pagesize": page_size}
        
        response = requests.get(url, headers=self._get_headers(), params=params)
        response.raise_for_status()
        return response.json().get('list', [])
    
    def get_certificate(self, cert_id):
        """Get specific certificate details"""
        url = f"{self.base_url}/certificate/{cert_id}"
        response = requests.get(url, headers=self._get_headers())
        if response.status_code == 200:
            return response.json()
        return None
    
    def delete_certificate(self, cert_id):
        """Delete a certificate by ID"""
        url = f"{self.base_url}/certificate/{cert_id}"
        response = requests.delete(url, headers=self._get_headers())
        
        if response.status_code == 204:
            self._log(f"✓ Deleted certificate ID: {cert_id}")
            return True
        else:
            self._log(f"✗ Failed to delete certificate {cert_id}: {response.status_code} - {response.text}")
            return False
    
    def get_browser_access_apps(self):
        """Get all Browser Access application segments"""
        url = f"{self.base_url}/application"
        params = {"applicationType": "BROWSER_ACCESS", "page": 1, "pagesize": 500}

        self._log("Fetching Browser Access applications...")
        response = requests.get(url, headers=self._get_headers(), params=params)
        response.raise_for_status()

        response_data = response.json()
        all_apps = response_data.get('list', [])

        self._log(f"Found {len(all_apps)} Browser Access application segments")
        return all_apps
    
    def get_application(self, app_id):
        """Get specific application details"""
        url = f"{self.base_url}/application/{app_id}"
        response = requests.get(url, headers=self._get_headers())
        response.raise_for_status()
        return response.json()
    
    def update_application(self, app_id, app_config):
        """Update application configuration"""
        url = f"{self.base_url}/application/{app_id}"
        response = requests.put(url, headers=self._get_headers(), json=app_config)
        
        if response.status_code == 204:
            return True
        else:
            self._log(f"✗ Failed to update app {app_id}: {response.status_code} - {response.text}")
            response.raise_for_status()
    
    def get_pra_portals(self):
        """Get all PRA Portals"""
        url = f"{self.base_url}/praPortal"
        
        self._log("Fetching PRA Portals...")
        response = requests.get(url, headers=self._get_headers())
        response.raise_for_status()
        
        portals = response.json().get('list', [])
        self._log(f"Found {len(portals)} PRA Portals")
        return portals
    
    def get_pra_portal(self, portal_id):
        """Get specific PRA portal details"""
        url = f"{self.base_url}/praPortal/{portal_id}"
        response = requests.get(url, headers=self._get_headers())
        response.raise_for_status()
        return response.json()
    
    def update_pra_portal(self, portal_id, portal_config):
        """Update PRA portal configuration"""
        url = f"{self.base_url}/praPortal/{portal_id}"
        response = requests.put(url, headers=self._get_headers(), json=portal_config)
        
        if response.status_code == 204:
            return True
        else:
            self._log(f"✗ Failed to update PRA portal {portal_id}: {response.status_code} - {response.text}")
            response.raise_for_status()
    
    def is_certificate_in_use(self, cert_id, exclude_resources=None):
        """Check if a certificate is being used by any resource"""
        if exclude_resources is None:
            exclude_resources = {'apps': set(), 'pra_portals': set()}
        
        all_apps = self.get_browser_access_apps()
        for app in all_apps:
            if app['id'] in exclude_resources.get('apps', set()):
                continue
            
            clientless_apps = app.get('clientlessApps', [])
            for ca in clientless_apps:
                if ca.get('certificateId') == cert_id:
                    return True, 'app', app
        
        pra_portals = self.get_pra_portals()
        for portal in pra_portals:
            if portal['id'] in exclude_resources.get('pra_portals', set()):
                continue
            
            if portal.get('certificateId') == cert_id:
                return True, 'pra_portal', portal
        
        return False, None, None

def main():
    if not all([CERT_PATH, KEY_PATH, DOMAIN]):
        print("Usage: script.py <cert_path> <key_path> <domain>")
        sys.exit(1)
    
    client = ZPAOneAPIClient(ZIDENTITY_BASE_URL, ONEAPI_BASE_URL, ZPA_CLIENT_ID, ZPA_CLIENT_SECRET, ZPA_CUSTOMER_ID)
    
    client._log(f"=== Starting ZPA certificate update for {DOMAIN} ===")
    client._log(f"Using ZIdentity: {ZIDENTITY_BASE_URL}")
    client._log(f"Using OneAPI: {ONEAPI_BASE_URL}")
    
    try:
        cert_name = f"{DOMAIN.replace('*.', 'wildcard-')}-{int(time.time())}"
        description = f"Auto-uploaded by acme.sh on {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"
        
        new_cert = client.upload_certificate(CERT_PATH, KEY_PATH, cert_name, description)
        new_cert_id = new_cert['id']
        client._log(f"New certificate ID: {new_cert_id}")
        
        domain_base = DOMAIN.replace('*.', '')
        
        old_cert_ids = set()
        updated_resources = {'apps': set(), 'pra_portals': set()}
        
        client._log(f"\n--- Processing Browser Access Applications ---")
        all_apps = client.get_browser_access_apps()
        
        for app in all_apps:
            clientless_apps = app.get('clientlessApps', [])
            if not clientless_apps:
                # List response may omit clientlessApps detail; fetch full app to check domains
                full_app = client.get_application(app['id'])
                clientless_apps = full_app.get('clientlessApps', [])

            app_matches = False
            for ca in clientless_apps:
                domain = ca.get('domain', '')
                domain_check = domain.replace('*.', '')
                
                if domain_check == domain_base or domain_check.endswith('.' + domain_base):
                    app_matches = True
                    old_cert_id = ca.get('certificateId')
                    if old_cert_id:
                        old_cert_ids.add(old_cert_id)
                    break
            
            if app_matches:
                client._log(f"  Found app: {app['name']} (ID: {app['id']})")
                
                app_config = client.get_application(app['id'])
                
                for ca in app_config.get('clientlessApps', []):
                    domain = ca.get('domain', '')
                    domain_check = domain.replace('*.', '')
                    
                    if domain_check == domain_base or domain_check.endswith('.' + domain_base):
                        old_cert_id = ca.get('certificateId')
                        ca['certificateId'] = new_cert_id
                        client._log(f"    Updated domain '{domain}' from cert {old_cert_id} to {new_cert_id}")
                
                client.update_application(app['id'], app_config)
                client._log(f"  ✓ Application updated")
                updated_resources['apps'].add(app['id'])
                time.sleep(0.5)
        
        client._log(f"\n--- Processing PRA Portals ---")
        pra_portals = client.get_pra_portals()
        
        for portal in pra_portals:
            if portal.get('certificateId') is None or portal.get('certificateId') == 0:
                client._log(f"  Skipping PRA Portal: {portal['name']} (using Zscaler-managed cert)")
                continue
            
            domain = portal.get('domain', '')
            domain_check = domain.replace('*.', '')
            
            if domain_check == domain_base or domain_check.endswith('.' + domain_base):
                client._log(f"  Found PRA Portal: {portal['name']} (ID: {portal['id']})")
                
                old_cert_id = portal.get('certificateId')
                if old_cert_id:
                    old_cert_ids.add(old_cert_id)
                
                portal_config = client.get_pra_portal(portal['id'])
                portal_config['certificateId'] = new_cert_id
                
                client.update_pra_portal(portal['id'], portal_config)
                client._log(f"  ✓ PRA Portal updated from cert {old_cert_id} to {new_cert_id}")
                updated_resources['pra_portals'].add(portal['id'])
                time.sleep(0.5)
        
        total_updated = len(updated_resources['apps']) + len(updated_resources['pra_portals'])
        client._log(f"\n✓ Successfully updated {total_updated} resources:")
        client._log(f"  - Browser Access Apps: {len(updated_resources['apps'])}")
        client._log(f"  - PRA Portals: {len(updated_resources['pra_portals'])}")
        
        if total_updated == 0:
            client._log("WARNING: No matching resources found! Certificate uploaded but not assigned.")
            client._log(f"=== Certificate update completed (no resources updated) ===\n")
            return
        
        client._log("\nWaiting for portal updates to propagate before cleanup...")
        time.sleep(5)
        client._log("--- Checking for old certificates to clean up ---")
        
        certs_deleted = 0
        certs_skipped = 0
        
        for old_cert_id in old_cert_ids:
            if old_cert_id == new_cert_id:
                continue
            
            in_use, resource_type, resource = client.is_certificate_in_use(old_cert_id, exclude_resources=updated_resources)
            
            if in_use:
                client._log(f"  Skipping cert {old_cert_id} - still in use by {resource_type}: {resource['name']}")
                certs_skipped += 1
            else:
                cert_info = client.get_certificate(old_cert_id)
                cert_name_old = cert_info['name'] if cert_info else old_cert_id
                
                client._log(f"  Deleting old certificate: {cert_name_old} (ID: {old_cert_id})")
                if client.delete_certificate(old_cert_id):
                    certs_deleted += 1
                else:
                    client._log(f"  WARNING: Failed to delete certificate {old_cert_id}")
        
        if certs_deleted > 0:
            client._log(f"✓ Deleted {certs_deleted} old certificate(s)")
        if certs_skipped > 0:
            client._log(f"  Skipped {certs_skipped} certificate(s) still in use")
        
        client._log(f"\n=== Certificate update completed successfully ===\n")
        
    except Exception as e:
        client._log(f"✗✗✗ ERROR: {str(e)}")
        import traceback
        client._log(traceback.format_exc())
        raise

if __name__ == "__main__":
    main()
