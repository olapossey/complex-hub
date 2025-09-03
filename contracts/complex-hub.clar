;; ----------------------------------------------------------
;; Contract: complex-hub.clar
;; A complex integrated Clarity contract (Staking, DAO, Lending,
;; NFT-collateral, Insurance, Prediction market, Reputation)
;; ----------------------------------------------------------

(define-constant ERR_NOT_FOUND (err u100))
(define-constant ERR_UNAUTHORIZED (err u101))
(define-constant ERR_INSUFFICIENT_FUNDS (err u102))
(define-constant ERR_ALREADY_EXECUTED (err u103))
(define-constant ERR_INVALID (err u104))

;; -------------------------
;; Global counters & vars
;; -------------------------
(define-data-var stake-total uint u0)
(define-data-var proposal-counter uint u1)
(define-data-var loan-counter uint u1)
(define-data-var pool-counter uint u1)
(define-data-var market-counter uint u1)

;; DAO treasury (STX)
(define-data-var dao-treasury uint u0)

;; -------------------------
;; STORAGE MAPS
;; -------------------------
;; staking balances
(define-map stakes
  { staker: principal }
  { amount: uint, start-block: uint })

;; simple proposal structure
(define-map proposals
  { id: uint }
  { proposer: principal, description: (string-ascii 200), votes-for: uint, votes-against: uint, executed: bool })

;; reputation per user
(define-map reputation
  { user: principal }
  { score: int })

;; simple loans backed by NFT-like collateral
;; Note: NFT is represented by (coll-contract principal, token-id uint) tuple in metadata
(define-map loans
  { id: uint }
  { borrower: principal, amount: uint, funded: uint, repaid: uint, collateral_contract: (optional principal), collateral_token_id: (optional uint), active: bool })

;; insurance pools
(define-map insurance-pools
  { id: uint }
  { creator: principal, premium: uint, coverage: uint, balance: uint })

;; insurance claims
(define-map insurance-claims
  { id: uint }
  { pool-id: uint, claimant: principal, amount: uint, approved: bool, paid: bool })

;; simple prediction markets
(define-map markets
  { id: uint }
  { creator: principal, question: (string-ascii 200), yes-pool: uint, no-pool: uint, resolved: bool, outcome: (optional bool) })

;; bets map: (market-id, bettor) -> {option, amount, claimed}
(define-map bets
  { market-id: uint, bettor: principal }
  { option: bool, amount: uint, claimed: bool })

;; -------------------------
;; HELPERS
;; -------------------------

(define-private (safe-add (a uint) (b uint))
  (+ a b))

(define-private (safe-sub (a uint) (b uint))
  (if (>= a b)
      (ok (- a b))
      (err u102)))

;; -------------------------
;; STAKING MODULE
;; -------------------------
(define-public (stake (amount uint))
  (match (stx-transfer? amount tx-sender (as-contract tx-sender))
    success
      (begin
        ;; record stake
        (let ((existing (map-get? stakes { staker: tx-sender })))
          (if (is-some existing)
              (map-set stakes { staker: tx-sender }
                       { amount: (+ (get amount (unwrap-panic existing)) amount), start-block: burn-block-height })
              (map-set stakes { staker: tx-sender } { amount: amount, start-block: burn-block-height })))
        (var-set stake-total (safe-add (var-get stake-total) amount))
        (ok true))
    err (err u102)))

(define-public (unstake (amount uint))
  (let ((s (map-get? stakes { staker: tx-sender })))
    (match s st
      (let ((bal (get amount st)))
        (if (>= bal amount)
            (begin
              ;; remove/adjust
              (if (> bal amount)
                  (map-set stakes { staker: tx-sender } { amount: (- bal amount), start-block: (get start-block st) })
                  (map-delete stakes { staker: tx-sender }))
              ;; send STX back
              (match (stx-transfer? amount (as-contract tx-sender) tx-sender)
                success (begin
                          (var-set stake-total (unwrap-panic (safe-sub (var-get stake-total) amount)))
                          (ok true))
                err (err u102)))
            (err u102)))
      (err u100))))

(define-public (distribute-staking-rewards (amount uint))
  ;; simple: move amount from caller into dao-treasury and credit proportional rewards off-chain / later
  (match (stx-transfer? amount tx-sender (as-contract tx-sender))
    success (begin
      (var-set dao-treasury (+ (var-get dao-treasury) amount))
      (ok true))
    err (err u102)))

;; -------------------------
;; DAO: proposals & voting
;; -------------------------
(define-public (create-proposal (description (string-ascii 200)))
  (let ((id (var-get proposal-counter)))
    (map-set proposals { id: id } { proposer: tx-sender, description: description, votes-for: u0, votes-against: u0, executed: false })
    (var-set proposal-counter (+ id u1))
    (ok id)))

(define-public (vote-proposal (proposal-id uint) (support bool))
  ;; voting weight = staked amount (simple)
  (let ((p (map-get? proposals { id: proposal-id })))
    (match p prop
      (let ((st (map-get? stakes { staker: tx-sender })))
        (let ((weight (if (is-some st) (get amount (unwrap-panic st)) u0)))
          (if support
              (map-set proposals { id: proposal-id }
                       (merge prop { votes-for: (+ (get votes-for prop) weight) }))
              (map-set proposals { id: proposal-id }
                       (merge prop { votes-against: (+ (get votes-against prop) weight) })))
          (ok weight)))
      (err u100))))

(define-public (execute-proposal (proposal-id uint))
  (let ((p (map-get? proposals { id: proposal-id })))
    (match p prop
      (if (get executed prop)
          (err u103)
          (let ((for (get votes-for prop)) (against (get votes-against prop)))
            (if (> for against)
                (begin
                  ;; NOTE: in a real system you'd parse & apply actions; here we just mark executed
                  (map-set proposals { id: proposal-id } (merge prop { executed: true }))
                  (ok true))
                (err u104))))
      (err u100))))

;; -------------------------
;; REPUTATION
;; -------------------------
(define-public (update-reputation (user principal) (delta int))
  (let ((r (map-get? reputation { user: user })))
    (if (is-some r)
        (map-set reputation { user: user } { score: (+ (get score (unwrap-panic r)) delta) })
        (map-set reputation { user: user } { score: delta }))
    (ok true)))

(define-read-only (get-reputation (user principal))
  (match (map-get? reputation { user: user })
    entry (ok (get score entry))
    (ok (to-int u0))))

;; -------------------------
;; LENDING (NFT-collateral model)
;; -------------------------
(define-public (request-loan (amount uint) (collateral_contract (optional principal)) (collateral_token_id (optional uint)))
  (let ((id (var-get loan-counter)))
    (map-set loans { id: id } { borrower: tx-sender, amount: amount, funded: u0, repaid: u0, collateral_contract: collateral_contract, collateral_token_id: collateral_token_id, active: true })
    (var-set loan-counter (+ id u1))
    (ok id)))

(define-public (fund-loan (loan-id uint) (amount uint))
  (let ((L (map-get? loans { id: loan-id })))
    (match L l
      (if (not (get active l)) 
          (err u104)
          (match (stx-transfer? amount tx-sender (as-contract tx-sender))
            success (begin
              (map-set loans { id: loan-id } (merge l { funded: (+ (get funded l) amount) }))
              ;; forward funds to borrower (in a real flow probably escrow to contract)
              (match (stx-transfer? amount (as-contract tx-sender) (get borrower l))
                s (ok true)
                e (err u102)))
            err (err u102)))
      (err u100))))

(define-public (repay-loan (loan-id uint) (amount uint))
  (let ((L (map-get? loans { id: loan-id })))
    (match L l
      (if (not (get active l))
          (err u104)
          (match (stx-transfer? amount tx-sender (as-contract tx-sender))
            success (begin
              (map-set loans { id: loan-id } (merge l { repaid: (+ (get repaid l) amount) }))
              ;; if repaid >= amount, mark inactive, return collateral to borrower (off-chain or via NFT transfer)
              (begin 
                (if (>= (+ (get repaid l) amount) (get amount l))
                    (map-set loans { id: loan-id } (merge l { active: false }))
                    true)
                (ok true))
            )
            err (err u102)))
      (err u100))))

;; -------------------------
;; INSURANCE
;; -------------------------
(define-public (create-insurance-pool (premium uint) (coverage uint))
  (let ((id (var-get pool-counter)))
    (map-set insurance-pools { id: id } { creator: tx-sender, premium: premium, coverage: coverage, balance: u0 })
    (var-set pool-counter (+ id u1))
    (ok id)))

(define-public (buy-policy (pool-id uint))
  (let ((pool (map-get? insurance-pools { id: pool-id })))
    (match pool p
      (match (stx-transfer? (get premium p) tx-sender (as-contract tx-sender))
        success (begin
          (map-set insurance-pools { id: pool-id } (merge p { balance: (+ (get balance p) (get premium p)) }))
          (ok true))
        err (err u102))
      (err u100))))

(define-public (submit-claim (pool-id uint) (amount uint))
  (let ((id (var-get pool-counter))) ;; reuse counter namespace? keep separate in prod
    (map-set insurance-claims { id: id } { pool-id: pool-id, claimant: tx-sender, amount: amount, approved: false, paid: false })
    (var-set pool-counter (+ (var-get pool-counter) u1))
    (ok id)))

(define-public (vote-claim (claim-id uint) (approve bool))
  ;; in this simplified version, any staker can call and approve; real impl should track votes
  (let ((c (map-get? insurance-claims { id: claim-id })))
    (match c 
      cl (begin
        (map-set insurance-claims { id: claim-id } (merge cl { approved: approve }))
        (ok true))
      (err u100))))

(define-public (payout-claim (claim-id uint))
  (let ((c (map-get? insurance-claims { id: claim-id })))
    (match c cl
      (if (and (get approved cl) (not (get paid cl)))
          (let ((pool (map-get? insurance-pools { id: (get pool-id cl) })))
            (match pool p
              (if (>= (get balance p) (get amount cl))
                  (begin
                    ;; transfer payout to claimant
                    (match (stx-transfer? (get amount cl) (as-contract tx-sender) (get claimant cl))
                      success (begin
                        (map-set insurance-pools { id: (get pool-id cl) } (merge p { balance: (- (get balance p) (get amount cl)) }))
                        (map-set insurance-claims { id: claim-id } (merge cl { paid: true }))
                        (ok true))
                      err (err u102)))
                  (err u102))
              (err u100)))
          (err u104))
      (err u100))))

;; -------------------------
;; PREDICTION MARKET
;; -------------------------
(define-public (create-market (question (string-ascii 200)))
  (let ((id (var-get market-counter)))
    (map-set markets { id: id } { creator: tx-sender, question: question, yes-pool: u0, no-pool: u0, resolved: false, outcome: none })
    (var-set market-counter (+ id u1))
    (ok id)))

(define-public (place-bet (market-id uint) (option bool) (amount uint))
  (let ((m (map-get? markets { id: market-id })))
    (match m mm
      (if (get resolved mm) (err u104)
        (match (stx-transfer? amount tx-sender (as-contract tx-sender))
          success (begin
            (if option
                (map-set markets { id: market-id } (merge mm { yes-pool: (+ (get yes-pool mm) amount) }))
                (map-set markets { id: market-id } (merge mm { no-pool: (+ (get no-pool mm) amount) })))
            (map-set bets { market-id: market-id, bettor: tx-sender } { option: option, amount: amount, claimed: false })
            (ok true))
          err (err u102)))
      (err u100))))

(define-public (resolve-market (market-id uint) (outcome bool))
  ;; In production, this should be oracle/DAO-driven. Here, creator may resolve.
  (let ((m (map-get? markets { id: market-id })))
    (match m mm
      (if (is-eq (get creator mm) tx-sender)
          (begin
            (map-set markets { id: market-id } (merge mm { resolved: true, outcome: (some outcome) }))
            (ok true))
          (err u101))
      (err u100))))

(define-public (claim-winnings (market-id uint))
  (let ((b (map-get? bets { market-id: market-id, bettor: tx-sender })))
    (match b bt
      (let ((m (map-get? markets { id: market-id })))
        (match m mm
          (if (and (get resolved mm) (is-eq (get option bt) (unwrap-panic (get outcome mm))))
              (let ((winning-pool (if (get option bt) (get yes-pool mm) (get no-pool mm)))
                    (losing-pool  (if (get option bt) (get no-pool mm) (get yes-pool mm))))
                ;; simplistic payout: return original + share of losing pool proportionally
                (let ((payout (+ (get amount bt)
                                 (/ (* (get amount bt) losing-pool) winning-pool))))
                  (match (stx-transfer? payout (as-contract tx-sender) tx-sender)
                    success (begin
                      (map-set bets { market-id: market-id, bettor: tx-sender } (merge bt { claimed: true }))
                      (ok payout))
                    err (err u102))))
              (err u104))
          (err u100)))
      (err u100))))

;; -------------------------
;; VIEW HELPERS
;; -------------------------
(define-read-only (get-stake (who principal))
  (match (map-get? stakes { staker: who })
    entry (ok (get amount entry))
    (ok u0)))

(define-read-only (get-proposal (id uint))
  (match (map-get? proposals { id: id })
    proposal (ok proposal)
    (err u100)))

(define-read-only (get-loan (id uint))
  (match (map-get? loans { id: id })
    loan-data (ok loan-data)
    (err u100)))
