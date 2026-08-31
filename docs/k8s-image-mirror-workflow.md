# Minimal Kubernetes Image Mirror Workflow

This workflow mirrors only the Kubernetes images you use, similar in spirit to `myrepo.sh`:

1. Keep an explicit image list (`images/kubernetes-v1.36.4.txt`).
2. Mirror those images locally with `image-repo.sh`.
3. Optionally sync the local mirror to your internal host over rsync.
4. Publish mirrored images from local storage into your internal registry with `image-repo.sh --publish-only`.

By default this setup uses single-architecture copy (`linux/amd64`) for speed.
Use `--all-arches` only when you explicitly need multi-architecture manifests.

## Files

- `image-repo.sh`: mirror + optional rsync sync
- `image-repo.cfg`: defaults (paths, remote host, sync settings)
- `images/*.txt`: image lists, for example `images/kubernetes-v1.36.4.txt` (minimal kubeadm
  set) or `images/calico-v3.32.1.txt` (pinned Calico set)

Image lists are environment-specific and therefore excluded from version control; create the
list your deployment needs and point `IMAGES_FILE` at it. Each line holds one fully qualified
image reference.


## Step 1: Dry-run mirror plan

```bash
cd ~/repo-handler
./image-repo.sh --dry-run --no-sync
```

## Step 2: Mirror images locally

```bash
cd ~/repo-handler
./image-repo.sh --no-sync
```

Optional multi-arch mirror (slower):

```bash
cd ~/repo-handler
./image-repo.sh --no-sync --all-arches
```

Local output default:

- `/repo/images/kubernetes/v1.36/registry.k8s.io/...`
- lock file: `/repo/images/kubernetes/v1.36/images.lock`

## Step 3: Optional sync to internal host (myrepo-style)

```bash
cd ~/repo-handler
./image-repo.sh --sync-only
```

Default sync target from config:

- `mgmt3:D:/repo/OracleLinux/OL9/kubernetes-images/v1.36`

## Step 4: Publish to internal registry

Default (uses `image-repo.cfg` values for `TARGET_REGISTRY`, `TARGET_NAMESPACE`, `DEST_TLS_VERIFY`):

```bash
cd ~/repo-handler
./image-repo.sh --publish-only
```

Optional multi-arch publish (slower):

```bash
cd ~/repo-handler
./image-repo.sh --publish-only --all-arches
```

Override example (only when needed):

```bash
cd ~/repo-handler
./image-repo.sh --publish-only \
  --target-registry mgmt2.kafir.police.hu:5000 \
  --target-namespace registry.k8s.io \
  --dest-tls-verify false
```

`image-repo.sh` is the only supported command for mirror/sync/publish operations.
Publication uses three retries by default and verifies the destination manifest
with `skopeo inspect` before reporting success. Override the defaults with:

```bash
./image-repo.sh --publish-only \
  --publish-retry-times 5 \
  --publish-retry-delay 15s
```

An interrupted transfer may leave blobs in the registry without a usable tag.
Always verify the final tag with `skopeo inspect`; a successful manifest check is
the completion criterion.

This produces image names like:

- `mgmt2.kafir.police.hu:5000/registry.k8s.io/kube-apiserver:v1.36.4`
- `mgmt2.kafir.police.hu:5000/registry.k8s.io/coredns/coredns:v1.14.2`

## kubeadm usage

In kubeadm config, set:

- `imageRepository: mgmt2.kafir.police.hu:5000/registry.k8s.io`

Then run `kubeadm config images pull` and `kubeadm init` using that config.
