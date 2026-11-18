# NovaPay Blameless Incident Postmortem Template

- **Incident ID:** `INC-0X`
- **Severity:** `SEV-1` / `SEV-2`
- **Incident Commander:** Sarah Chen (SRE Lead)
- **Investigating Platform Engineer:**
- **Affected Services / Namespaces:**
- **Primary Envoy Response Flag Observed:** (`NR` / `UF` / `UO` / `UT` / `UC` / `UH` / `UAEX`)

---

## 1. Executive Summary & Customer Impact
*Describe what failed, which upstream/downstream calls were impacted, what HTTP status codes or latencies users experienced, and how long the condition persisted.*

---

## 2. Diagnostic Evidence & Timeline
*Record the exact evidence gathered using the 5-Step Istio Troubleshooting Methodology:*

1. **Control Plane Validation (`istioctl analyze`)**:
   ```text
   ```
2. **xDS Synchronization (`istioctl proxy-status`)**:
   ```text
   ```
3. **Envoy Access Log Entry & Response Flag**:
   ```text
   ```
4. **xDS Config Dump Inspection (`istioctl proxy-config ...`)**:
   ```text
   ```

---

## 3. Root Cause Analysis (The 5 Whys)
1. **Why did the user-facing request fail?**
2. **Why did the client/server Envoy proxy emit that specific response flag?**
3. **Why was the Envoy xDS state (`LDS`/`RDS`/`CDS`/`EDS`/`SDS`) configured that way?**
4. **Why did the Istio CRD / Kubernetes manifest produce that xDS state?**
5. **Why wasn't this caught before reaching production?**

---

## 4. Remediation Applied
*Paste the exact YAML diff or command that resolved the incident and restored healthy traffic flow.*

```yaml
```

---

## 5. Preventative Action Items
| Action Item | Owner | Category (`CI Gate` / `Alerting` / `Policy`) | Target Completion |
| :--- | :--- | :--- | :--- |
| e.g., Add `istioctl analyze --use-kube=false` to GitOps PR check | Platform Team | `CI Gate` | Immediate |

