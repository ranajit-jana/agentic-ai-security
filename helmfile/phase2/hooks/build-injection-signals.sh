#!/bin/bash
set -euo pipefail

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: injection-signals-pvc
  namespace: infra
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
EOF

kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: build-injection-signals
  namespace: infra
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: build
          image: python:3.11-slim
          command: ["/bin/bash", "-c"]
          args:
            - |
              pip install -q requests numpy
              git clone --depth 1 https://github.com/Arcanum-Sec/arc_pi_taxonomy /tmp/taxonomy
              python /scripts/build_injection_embeddings.py \
                --taxonomy /tmp/taxonomy \
                --output /data/injection_signals.pkl \
                --model nomic-embed-text:v1.5 \
                --ollama-url http://ollama-embed.infra.svc.cluster.local:11434
          volumeMounts:
            - name: signal-data
              mountPath: /data
            - name: scripts
              mountPath: /scripts
      volumes:
        - name: signal-data
          persistentVolumeClaim:
            claimName: injection-signals-pvc
        - name: scripts
          configMap:
            name: injection-build-scripts
EOF

kubectl wait --for=condition=complete job/build-injection-signals \
  -n infra --timeout=600s

echo "Injection signal index built at /data/injection_signals.pkl"
