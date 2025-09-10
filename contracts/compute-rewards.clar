;; title: compute-rewards
;; version: 1.0.0
;; summary: Smart contract for managing compute provider rewards and incentives
;; description: Handles staking, training session tracking, and reward distribution for compute providers

;; Error constants
(define-constant ERR-UNAUTHORIZED (err u100))
(define-constant ERR-INSUFFICIENT-FUNDS (err u101))
(define-constant ERR-INVALID-AMOUNT (err u102))
(define-constant ERR-SESSION-NOT-FOUND (err u103))
(define-constant ERR-ALREADY-CLAIMED (err u104))
(define-constant ERR-NOT-VESTED (err u105))
(define-constant ERR-PROVIDER-NOT-FOUND (err u106))
(define-constant ERR-INVALID-SESSION (err u107))
(define-constant ERR-SESSION-ALREADY-EXISTS (err u108))
(define-constant ERR-MINIMUM-STAKE-NOT-MET (err u109))

;; Contract constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant MINIMUM-STAKE u1000000) ;; 1 STX minimum stake
(define-constant BASE-REWARD-RATE u100) ;; Base rewards per compute unit
(define-constant VESTING-PERIOD u144) ;; ~24 hours in blocks
(define-constant MAX-PROVIDERS-PER-SESSION u10)

;; Data variables
(define-data-var total-staked uint u0)
(define-data-var total-rewards-distributed uint u0)
(define-data-var reward-rate uint BASE-REWARD-RATE)
(define-data-var contract-paused bool false)
(define-data-var session-counter uint u0)

;; Data maps

;; Provider stake and status tracking
(define-map providers
  { provider: principal }
  {
    stake-amount: uint,
    total-rewards-earned: uint,
    reputation-score: uint,
    is-active: bool,
    stake-block: uint
  }
)

;; Training session data
(define-map training-sessions
  { session-id: uint }
  {
    requester: principal,
    total-compute-units: uint,
    reward-per-unit: uint,
    start-block: uint,
    end-block: uint,
    is-completed: bool,
    total-reward-pool: uint
  }
)

;; Provider participation in sessions
(define-map session-participation
  { session-id: uint, provider: principal }
  {
    compute-units-contributed: uint,
    reward-amount: uint,
    is-claimed: bool,
    claim-block: uint
  }
)

;; Vesting schedule for rewards
(define-map vesting-schedule
  { provider: principal, session-id: uint }
  {
    total-amount: uint,
    vested-amount: uint,
    vest-start-block: uint,
    vest-end-block: uint
  }
)

;; Public functions

;; Stake STX to become a compute provider
(define-public (stake-as-provider (amount uint))
  (let ((current-stake (default-to u0 (get stake-amount (map-get? providers {provider: tx-sender})))))
    (begin
      (asserts! (not (var-get contract-paused)) ERR-UNAUTHORIZED)
      (asserts! (>= amount MINIMUM-STAKE) ERR-MINIMUM-STAKE-NOT-MET)
      
      ;; Transfer STX to contract
      (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
      
      ;; Update provider data
      (map-set providers
        {provider: tx-sender}
        {
          stake-amount: (+ current-stake amount),
          total-rewards-earned: (default-to u0 (get total-rewards-earned (map-get? providers {provider: tx-sender}))),
          reputation-score: (default-to u0 (get reputation-score (map-get? providers {provider: tx-sender}))),
          is-active: true,
          stake-block: block-height
        }
      )
      
      ;; Update total staked
      (var-set total-staked (+ (var-get total-staked) amount))
      (ok true)
    )
  )
)

;; Unstake STX (partial or full)
(define-public (unstake (amount uint))
  (let (
    (provider-data (unwrap! (map-get? providers {provider: tx-sender}) ERR-PROVIDER-NOT-FOUND))
    (current-stake (get stake-amount provider-data))
  )
    (begin
      (asserts! (not (var-get contract-paused)) ERR-UNAUTHORIZED)
      (asserts! (>= current-stake amount) ERR-INSUFFICIENT-FUNDS)
      (asserts! (> amount u0) ERR-INVALID-AMOUNT)
      
      ;; Check if remaining stake meets minimum requirement
      (asserts! (or (is-eq (- current-stake amount) u0) 
                    (>= (- current-stake amount) MINIMUM-STAKE)) 
                ERR-MINIMUM-STAKE-NOT-MET)
      
      ;; Transfer STX back to provider
      (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
      
      ;; Update provider data
      (let ((new-stake (- current-stake amount)))
        (if (is-eq new-stake u0)
          (map-delete providers {provider: tx-sender})
          (map-set providers
            {provider: tx-sender}
            (merge provider-data {stake-amount: new-stake, is-active: (>= new-stake MINIMUM-STAKE)})
          )
        )
      )
      
      ;; Update total staked
      (var-set total-staked (- (var-get total-staked) amount))
      (ok true)
    )
  )
)

;; Create a new training session
(define-public (create-training-session (compute-units uint) (reward-pool uint))
  (let ((session-id (+ (var-get session-counter) u1)))
    (begin
      (asserts! (not (var-get contract-paused)) ERR-UNAUTHORIZED)
      (asserts! (> compute-units u0) ERR-INVALID-AMOUNT)
      (asserts! (> reward-pool u0) ERR-INVALID-AMOUNT)
      
      ;; Transfer reward pool to contract
      (try! (stx-transfer? reward-pool tx-sender (as-contract tx-sender)))
      
      ;; Create session
      (map-set training-sessions
        {session-id: session-id}
        {
          requester: tx-sender,
          total-compute-units: compute-units,
          reward-per-unit: (/ reward-pool compute-units),
          start-block: block-height,
          end-block: u0,
          is-completed: false,
          total-reward-pool: reward-pool
        }
      )
      
      ;; Update session counter
      (var-set session-counter session-id)
      (ok session-id)
    )
  )
)

;; Record compute contribution for a session
(define-public (record-compute-contribution (session-id uint) (provider principal) (compute-units uint))
  (let (
    (session-data (unwrap! (map-get? training-sessions {session-id: session-id}) ERR-SESSION-NOT-FOUND))
    (provider-data (unwrap! (map-get? providers {provider: provider}) ERR-PROVIDER-NOT-FOUND))
  )
    (begin
      (asserts! (not (var-get contract-paused)) ERR-UNAUTHORIZED)
      (asserts! (is-eq tx-sender (get requester session-data)) ERR-UNAUTHORIZED)
      (asserts! (not (get is-completed session-data)) ERR-INVALID-SESSION)
      (asserts! (get is-active provider-data) ERR-UNAUTHORIZED)
      (asserts! (> compute-units u0) ERR-INVALID-AMOUNT)
      
      (let ((reward-amount (* compute-units (get reward-per-unit session-data))))
        ;; Record participation
        (map-set session-participation
          {session-id: session-id, provider: provider}
          {
            compute-units-contributed: compute-units,
            reward-amount: reward-amount,
            is-claimed: false,
            claim-block: u0
          }
        )
        
        ;; Set up vesting schedule
        (map-set vesting-schedule
          {provider: provider, session-id: session-id}
          {
            total-amount: reward-amount,
            vested-amount: u0,
            vest-start-block: block-height,
            vest-end-block: (+ block-height VESTING-PERIOD)
          }
        )
        
        (ok true)
      )
    )
  )
)

;; Complete a training session
(define-public (complete-training-session (session-id uint))
  (let ((session-data (unwrap! (map-get? training-sessions {session-id: session-id}) ERR-SESSION-NOT-FOUND)))
    (begin
      (asserts! (not (var-get contract-paused)) ERR-UNAUTHORIZED)
      (asserts! (is-eq tx-sender (get requester session-data)) ERR-UNAUTHORIZED)
      (asserts! (not (get is-completed session-data)) ERR-INVALID-SESSION)
      
      ;; Mark session as completed
      (map-set training-sessions
        {session-id: session-id}
        (merge session-data {is-completed: true, end-block: block-height})
      )
      
      (ok true)
    )
  )
)

;; Claim vested rewards
(define-public (claim-rewards (session-id uint))
  (let (
    (participation (unwrap! (map-get? session-participation {session-id: session-id, provider: tx-sender}) ERR-SESSION-NOT-FOUND))
    (vesting (unwrap! (map-get? vesting-schedule {provider: tx-sender, session-id: session-id}) ERR-SESSION-NOT-FOUND))
    (session-data (unwrap! (map-get? training-sessions {session-id: session-id}) ERR-SESSION-NOT-FOUND))
  )
    (begin
      (asserts! (not (var-get contract-paused)) ERR-UNAUTHORIZED)
      (asserts! (not (get is-claimed participation)) ERR-ALREADY-CLAIMED)
      (asserts! (get is-completed session-data) ERR-INVALID-SESSION)
      (asserts! (>= block-height (get vest-end-block vesting)) ERR-NOT-VESTED)
      
      (let ((reward-amount (get reward-amount participation)))
        ;; Transfer rewards to provider
        (try! (as-contract (stx-transfer? reward-amount tx-sender tx-sender)))
        
        ;; Mark as claimed
        (map-set session-participation
          {session-id: session-id, provider: tx-sender}
          (merge participation {is-claimed: true, claim-block: block-height})
        )
        
        ;; Update vesting schedule
        (map-set vesting-schedule
          {provider: tx-sender, session-id: session-id}
          (merge vesting {vested-amount: reward-amount})
        )
        
        ;; Update provider total rewards
        (let ((provider-data (unwrap! (map-get? providers {provider: tx-sender}) ERR-PROVIDER-NOT-FOUND)))
          (map-set providers
            {provider: tx-sender}
            (merge provider-data {
              total-rewards-earned: (+ (get total-rewards-earned provider-data) reward-amount),
              reputation-score: (+ (get reputation-score provider-data) u1)
            })
          )
        )
        
        ;; Update total rewards distributed
        (var-set total-rewards-distributed (+ (var-get total-rewards-distributed) reward-amount))
        
        (ok reward-amount)
      )
    )
  )
)

;; Admin function to update reward rate
(define-public (update-reward-rate (new-rate uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (> new-rate u0) ERR-INVALID-AMOUNT)
    (var-set reward-rate new-rate)
    (ok true)
  )
)

;; Admin function to pause/unpause contract
(define-public (toggle-contract-pause)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (var-set contract-paused (not (var-get contract-paused)))
    (ok (var-get contract-paused))
  )
)

;; Read-only functions

;; Get provider information
(define-read-only (get-provider-info (provider principal))
  (map-get? providers {provider: provider})
)

;; Get training session information
(define-read-only (get-session-info (session-id uint))
  (map-get? training-sessions {session-id: session-id})
)

;; Get session participation info
(define-read-only (get-participation-info (session-id uint) (provider principal))
  (map-get? session-participation {session-id: session-id, provider: provider})
)

;; Get vesting information
(define-read-only (get-vesting-info (provider principal) (session-id uint))
  (map-get? vesting-schedule {provider: provider, session-id: session-id})
)

;; Get contract stats
(define-read-only (get-contract-stats)
  {
    total-staked: (var-get total-staked),
    total-rewards-distributed: (var-get total-rewards-distributed),
    current-reward-rate: (var-get reward-rate),
    is-paused: (var-get contract-paused),
    total-sessions: (var-get session-counter)
  }
)

;; Check if rewards are claimable
(define-read-only (can-claim-rewards (provider principal) (session-id uint))
  (match (map-get? vesting-schedule {provider: provider, session-id: session-id})
    vesting-data (and
                   (>= block-height (get vest-end-block vesting-data))
                   (match (map-get? session-participation {session-id: session-id, provider: provider})
                     participation-data (and
                                         (not (get is-claimed participation-data))
                                         (match (map-get? training-sessions {session-id: session-id})
                                           session-data (get is-completed session-data)
                                           false
                                         )
                                       )
                     false
                   )
                 )
    false
  )
)
