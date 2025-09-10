;; title: model-registry
;; version: 1.0.0
;; summary: Smart contract for AI model metadata registration and management
;; description: Handles model registration, ownership, metadata updates, and discovery features

;; Error constants
(define-constant ERR-UNAUTHORIZED (err u200))
(define-constant ERR-MODEL-NOT-FOUND (err u201))
(define-constant ERR-MODEL-ALREADY-EXISTS (err u202))
(define-constant ERR-INVALID-METADATA (err u203))
(define-constant ERR-MODEL-DEPRECATED (err u204))
(define-constant ERR-INVALID-OWNER (err u205))
(define-constant ERR-INVALID-HASH (err u206))
(define-constant ERR-NAME-TOO-LONG (err u207))
(define-constant ERR-DESCRIPTION-TOO_LONG (err u208))
(define-constant ERR-INVALID-VERSION (err u209))
(define-constant ERR-LICENSE-INVALID (err u210))

;; Contract constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant MAX-NAME-LENGTH u100)
(define-constant MAX-DESCRIPTION-LENGTH u500)
(define-constant MAX-DATASET-REF-LENGTH u200)
(define-constant MAX-MODELS-PER-PAGE u50)
(define-constant MODEL-HASH-LENGTH u64)

;; Model status constants
(define-constant STATUS-ACTIVE u1)
(define-constant STATUS-DEPRECATED u2)
(define-constant STATUS-PRIVATE u3)

;; Model type constants
(define-constant TYPE-CLASSIFICATION u1)
(define-constant TYPE-REGRESSION u2)
(define-constant TYPE-GENERATIVE u3)
(define-constant TYPE-REINFORCEMENT u4)
(define-constant TYPE-OTHER u5)

;; Data variables
(define-data-var total-models uint u0)
(define-data-var registry-paused bool false)
(define-data-var model-counter uint u0)

;; Data maps

;; Core model registry - maps model ID to metadata
(define-map models
  { model-id: uint }
  {
    name: (string-ascii 100),
    description: (string-ascii 500),
    model-hash: (string-ascii 64),
    dataset-reference: (string-ascii 200),
    owner: principal,
    created-at-block: uint,
    updated-at-block: uint,
    version: (string-ascii 20),
    model-type: uint,
    status: uint,
    license: (string-ascii 50),
    performance-metrics: (string-ascii 200),
    download-count: uint,
    is-public: bool
  }
)

;; Model name to ID mapping for uniqueness enforcement
(define-map model-names
  { name: (string-ascii 100) }
  { model-id: uint, owner: principal }
)

;; Owner to models mapping for efficient lookups
(define-map owner-models
  { owner: principal, model-id: uint }
  { registered-at-block: uint }
)

;; Model hash to ID mapping for duplicate prevention
(define-map model-hashes
  { model-hash: (string-ascii 64) }
  { model-id: uint }
)

;; Model tags for categorization and search
(define-map model-tags
  { model-id: uint, tag: (string-ascii 50) }
  { added-at-block: uint }
)

;; Model access permissions
(define-map model-permissions
  { model-id: uint, accessor: principal }
  {
    can-view: bool,
    can-download: bool,
    granted-at-block: uint,
    granted-by: principal
  }
)

;; Model version history
(define-map model-versions
  { model-id: uint, version: (string-ascii 20) }
  {
    model-hash: (string-ascii 64),
    updated-at-block: uint,
    change-notes: (string-ascii 300)
  }
)

;; Public functions

;; Register a new AI model
(define-public (register-model
    (name (string-ascii 100))
    (description (string-ascii 500))
    (model-hash (string-ascii 64))
    (dataset-ref (string-ascii 200))
    (version (string-ascii 20))
    (model-type uint)
    (license (string-ascii 50))
    (performance-metrics (string-ascii 200))
    (is-public bool)
  )
  (let ((model-id (+ (var-get model-counter) u1)))
    (begin
      (asserts! (not (var-get registry-paused)) ERR-UNAUTHORIZED)
      (asserts! (> (len name) u0) ERR-INVALID-METADATA)
      (asserts! (<= (len name) MAX-NAME-LENGTH) ERR-NAME-TOO-LONG)
      (asserts! (<= (len description) MAX-DESCRIPTION-LENGTH) ERR-DESCRIPTION-TOO_LONG)
      (asserts! (is-eq (len model-hash) MODEL-HASH-LENGTH) ERR-INVALID-HASH)
      (asserts! (and (>= model-type u1) (<= model-type u5)) ERR-INVALID-METADATA)
      
      ;; Check for duplicate name
      (asserts! (is-none (map-get? model-names {name: name})) ERR-MODEL-ALREADY-EXISTS)
      
      ;; Check for duplicate hash
      (asserts! (is-none (map-get? model-hashes {model-hash: model-hash})) ERR-MODEL-ALREADY-EXISTS)
      
      ;; Register the model
      (map-set models
        {model-id: model-id}
        {
          name: name,
          description: description,
          model-hash: model-hash,
          dataset-reference: dataset-ref,
          owner: tx-sender,
          created-at-block: block-height,
          updated-at-block: block-height,
          version: version,
          model-type: model-type,
          status: STATUS-ACTIVE,
          license: license,
          performance-metrics: performance-metrics,
          download-count: u0,
          is-public: is-public
        }
      )
      
      ;; Register name mapping
      (map-set model-names
        {name: name}
        {model-id: model-id, owner: tx-sender}
      )
      
      ;; Register hash mapping
      (map-set model-hashes
        {model-hash: model-hash}
        {model-id: model-id}
      )
      
      ;; Register owner mapping
      (map-set owner-models
        {owner: tx-sender, model-id: model-id}
        {registered-at-block: block-height}
      )
      
      ;; Store initial version
      (map-set model-versions
        {model-id: model-id, version: version}
        {
          model-hash: model-hash,
          updated-at-block: block-height,
          change-notes: "Initial version"
        }
      )
      
      ;; Update counters
      (var-set model-counter model-id)
      (var-set total-models (+ (var-get total-models) u1))
      
      (ok model-id)
    )
  )
)

;; Update model metadata (owner only)
(define-public (update-model-metadata
    (model-id uint)
    (description (string-ascii 500))
    (performance-metrics (string-ascii 200))
    (license (string-ascii 50))
  )
  (let ((model-data (unwrap! (map-get? models {model-id: model-id}) ERR-MODEL-NOT-FOUND)))
    (begin
      (asserts! (not (var-get registry-paused)) ERR-UNAUTHORIZED)
      (asserts! (is-eq tx-sender (get owner model-data)) ERR-UNAUTHORIZED)
      (asserts! (not (is-eq (get status model-data) STATUS-DEPRECATED)) ERR-MODEL-DEPRECATED)
      (asserts! (<= (len description) MAX-DESCRIPTION-LENGTH) ERR-DESCRIPTION-TOO_LONG)
      
      ;; Update model data
      (map-set models
        {model-id: model-id}
        (merge model-data {
          description: description,
          performance-metrics: performance-metrics,
          license: license,
          updated-at-block: block-height
        })
      )
      
      (ok true)
    )
  )
)

;; Update model version with new hash
(define-public (update-model-version
    (model-id uint)
    (new-hash (string-ascii 64))
    (version (string-ascii 20))
    (change-notes (string-ascii 300))
  )
  (let ((model-data (unwrap! (map-get? models {model-id: model-id}) ERR-MODEL-NOT-FOUND)))
    (begin
      (asserts! (not (var-get registry-paused)) ERR-UNAUTHORIZED)
      (asserts! (is-eq tx-sender (get owner model-data)) ERR-UNAUTHORIZED)
      (asserts! (not (is-eq (get status model-data) STATUS-DEPRECATED)) ERR-MODEL-DEPRECATED)
      (asserts! (is-eq (len new-hash) MODEL-HASH-LENGTH) ERR-INVALID-HASH)
      
      ;; Check for duplicate hash
      (asserts! (is-none (map-get? model-hashes {model-hash: new-hash})) ERR-MODEL-ALREADY-EXISTS)
      
      ;; Remove old hash mapping
      (map-delete model-hashes {model-hash: (get model-hash model-data)})
      
      ;; Update model with new hash and version
      (map-set models
        {model-id: model-id}
        (merge model-data {
          model-hash: new-hash,
          version: version,
          updated-at-block: block-height
        })
      )
      
      ;; Set new hash mapping
      (map-set model-hashes
        {model-hash: new-hash}
        {model-id: model-id}
      )
      
      ;; Store version history
      (map-set model-versions
        {model-id: model-id, version: version}
        {
          model-hash: new-hash,
          updated-at-block: block-height,
          change-notes: change-notes
        }
      )
      
      (ok true)
    )
  )
)

;; Transfer model ownership
(define-public (transfer-model-ownership (model-id uint) (new-owner principal))
  (let ((model-data (unwrap! (map-get? models {model-id: model-id}) ERR-MODEL-NOT-FOUND)))
    (begin
      (asserts! (not (var-get registry-paused)) ERR-UNAUTHORIZED)
      (asserts! (is-eq tx-sender (get owner model-data)) ERR-UNAUTHORIZED)
      (asserts! (not (is-eq (get status model-data) STATUS-DEPRECATED)) ERR-MODEL-DEPRECATED)
      (asserts! (not (is-eq new-owner tx-sender)) ERR-INVALID-OWNER)
      
      ;; Update model owner
      (map-set models
        {model-id: model-id}
        (merge model-data {
          owner: new-owner,
          updated-at-block: block-height
        })
      )
      
      ;; Update name mapping
      (map-set model-names
        {name: (get name model-data)}
        {model-id: model-id, owner: new-owner}
      )
      
      ;; Remove old owner mapping
      (map-delete owner-models {owner: tx-sender, model-id: model-id})
      
      ;; Add new owner mapping
      (map-set owner-models
        {owner: new-owner, model-id: model-id}
        {registered-at-block: block-height}
      )
      
      (ok true)
    )
  )
)

;; Deprecate a model (owner only)
(define-public (deprecate-model (model-id uint))
  (let ((model-data (unwrap! (map-get? models {model-id: model-id}) ERR-MODEL-NOT-FOUND)))
    (begin
      (asserts! (not (var-get registry-paused)) ERR-UNAUTHORIZED)
      (asserts! (is-eq tx-sender (get owner model-data)) ERR-UNAUTHORIZED)
      (asserts! (not (is-eq (get status model-data) STATUS-DEPRECATED)) ERR-MODEL-DEPRECATED)
      
      ;; Mark model as deprecated
      (map-set models
        {model-id: model-id}
        (merge model-data {
          status: STATUS-DEPRECATED,
          updated-at-block: block-height
        })
      )
      
      (ok true)
    )
  )
)

;; Toggle model public/private status
(define-public (toggle-model-visibility (model-id uint))
  (let ((model-data (unwrap! (map-get? models {model-id: model-id}) ERR-MODEL-NOT-FOUND)))
    (begin
      (asserts! (not (var-get registry-paused)) ERR-UNAUTHORIZED)
      (asserts! (is-eq tx-sender (get owner model-data)) ERR-UNAUTHORIZED)
      (asserts! (not (is-eq (get status model-data) STATUS-DEPRECATED)) ERR-MODEL-DEPRECATED)
      
      ;; Toggle visibility
      (map-set models
        {model-id: model-id}
        (merge model-data {
          is-public: (not (get is-public model-data)),
          updated-at-block: block-height
        })
      )
      
      (ok (not (get is-public model-data)))
    )
  )
)

;; Increment download count
(define-public (increment-download-count (model-id uint))
  (let ((model-data (unwrap! (map-get? models {model-id: model-id}) ERR-MODEL-NOT-FOUND)))
    (begin
      (asserts! (not (var-get registry-paused)) ERR-UNAUTHORIZED)
      (asserts! (or (get is-public model-data) (is-eq tx-sender (get owner model-data))) ERR-UNAUTHORIZED)
      (asserts! (is-eq (get status model-data) STATUS-ACTIVE) ERR-MODEL-DEPRECATED)
      
      ;; Increment download count
      (map-set models
        {model-id: model-id}
        (merge model-data {download-count: (+ (get download-count model-data) u1)})
      )
      
      (ok (+ (get download-count model-data) u1))
    )
  )
)

;; Admin function to pause/unpause registry
(define-public (toggle-registry-pause)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (var-set registry-paused (not (var-get registry-paused)))
    (ok (var-get registry-paused))
  )
)

;; Read-only functions

;; Get model information
(define-read-only (get-model-info (model-id uint))
  (map-get? models {model-id: model-id})
)

;; Get model by name
(define-read-only (get-model-by-name (name (string-ascii 100)))
  (match (map-get? model-names {name: name})
    name-data (map-get? models {model-id: (get model-id name-data)})
    none
  )
)

;; Get model by hash
(define-read-only (get-model-by-hash (model-hash (string-ascii 64)))
  (match (map-get? model-hashes {model-hash: model-hash})
    hash-data (map-get? models {model-id: (get model-id hash-data)})
    none
  )
)

;; Check if user owns a model
(define-read-only (is-model-owner (model-id uint) (user principal))
  (match (map-get? models {model-id: model-id})
    model-data (is-eq user (get owner model-data))
    false
  )
)

;; Get registry statistics
(define-read-only (get-registry-stats)
  {
    total-models: (var-get total-models),
    is-paused: (var-get registry-paused),
    current-model-counter: (var-get model-counter)
  }
)

;; Get models by owner (with pagination)
(define-read-only (get-models-by-owner (owner principal) (offset uint) (limit uint))
  (let ((actual-limit (if (> limit MAX-MODELS-PER-PAGE) MAX-MODELS-PER-PAGE limit)))
    {
      owner: owner,
      offset: offset,
      limit: actual-limit
      ;; Note: In a full implementation, this would return actual model data
      ;; For simplicity, returning metadata only
    }
  )
)

;; Get models by type (with pagination)
(define-read-only (get-models-by-type (model-type uint) (offset uint) (limit uint))
  (let ((actual-limit (if (> limit MAX-MODELS-PER-PAGE) MAX-MODELS-PER-PAGE limit)))
    {
      model-type: model-type,
      offset: offset,
      limit: actual-limit
    }
  )
)

;; Get public models (with pagination)
(define-read-only (get-public-models (offset uint) (limit uint))
  (let ((actual-limit (if (> limit MAX-MODELS-PER-PAGE) MAX-MODELS-PER-PAGE limit)))
    {
      offset: offset,
      limit: actual-limit,
      public-only: true
    }
  )
)

;; Get model version history
(define-read-only (get-model-version (model-id uint) (version (string-ascii 20)))
  (map-get? model-versions {model-id: model-id, version: version})
)

;; Check if model name is available
(define-read-only (is-name-available (name (string-ascii 100)))
  (is-none (map-get? model-names {name: name}))
)

;; Check if model hash exists
(define-read-only (hash-exists (model-hash (string-ascii 64)))
  (is-some (map-get? model-hashes {model-hash: model-hash}))
)
