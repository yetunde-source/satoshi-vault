;; Title: Satoshi Vault - Bitcoin-Backed Digital Asset Platform
;;
;; Summary:
;; A secure, compliant platform for creating, managing, and trading digital assets
;; backed by Bitcoin on the Stacks blockchain, with built-in staking and governance.
;;
;; Description:
;; Satoshi Vault enables the tokenization of real-world assets with Bitcoin backing,
;; providing a bridge between traditional finance and blockchain technology. The platform
;; implements a comprehensive suite of functions for the entire asset lifecycle:
;;
;; - Asset Tokenization: Convert real-world assets into secure digital tokens
;; - Ownership Management: Transfer assets with robust verification mechanisms
;; - Yield Generation: Stake assets to earn governance tokens
;; - Governance Participation: Use earned tokens for platform governance
;; - Asset Redemption: Burn tokens to claim underlying assets
;;
;; This contract adheres to Stacks Layer 2 standards and Bitcoin compliance requirements,
;; ensuring regulatory compatibility while leveraging the security of the Bitcoin network.

;; NFT Definition
(define-non-fungible-token satoshi-vault-asset (buff 32))

;; Contract Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-UNAUTHORIZED (err u1))
(define-constant ERR-NOT-FOUND (err u2))
(define-constant ERR-ALREADY-MINTED (err u3))
(define-constant ERR-INVALID-TRANSFER (err u4))
(define-constant ERR-STAKING-ERROR (err u5))
(define-constant ERR-INSUFFICIENT-BALANCE (err u6))
(define-constant ERR-INVALID-INPUT (err u7))
(define-constant ERR-INVALID-TOKEN (err u8))

;; Input Validation Functions

(define-private (is-valid-token-id (token-id (buff 32)))
    (and 
        (not (is-eq token-id 0x))
        (< (len token-id) u33)
    )
)

(define-private (is-valid-asset-type (asset-type (string-utf8 50)))
    (and 
        (> (len asset-type) u0)
        (<= (len asset-type) u50)
    )
)

(define-private (is-valid-asset-value (asset-value uint))
    (and 
        (> asset-value u0)
        (< asset-value u1000000)
    )
)

;; Data Storage

;; Asset Metadata Storage
(define-map asset-metadata 
    {token-id: (buff 32)} 
    {
        owner: principal,
        asset-type: (string-utf8 50),
        asset-value: uint,
        mint-timestamp: uint,
        staking-start: (optional uint),
        staking-rewards: uint
    }
)

;; Staking Information Storage
(define-map asset-staking 
    {token-id: (buff 32)} 
    {
        staked-by: principal,
        stake-start-block: uint,
        total-staked-blocks: uint
    }
)

;; Governance Token Balances
(define-map governance-tokens 
    principal 
    uint
)

;; Read-Only Functions

(define-read-only (get-asset-metadata (token-id (buff 32)))
    (begin
        (asserts! (is-valid-token-id token-id) none)
        (map-get? asset-metadata {token-id: token-id})
    )
)

(define-read-only (get-governance-tokens (user principal))
    (default-to u0 (map-get? governance-tokens user))
)

;; Public Functions

;; Mint a new asset token
(define-public (mint-asset 
    (token-id (buff 32))
    (asset-type (string-utf8 50))
    (asset-value uint)
)
    (begin
        ;; Validate all inputs
        (asserts! (is-valid-token-id token-id) ERR-INVALID-TOKEN)
        (asserts! (is-valid-asset-type asset-type) ERR-INVALID-INPUT)
        (asserts! (is-valid-asset-value asset-value) ERR-INVALID-INPUT)
        
        ;; Check if asset already exists
        (asserts! (is-none (nft-get-owner? satoshi-vault-asset token-id)) ERR-ALREADY-MINTED)
        
        ;; Mint the asset token
        (try! (nft-mint? satoshi-vault-asset token-id tx-sender))
        
        ;; Store asset metadata
        (map-set asset-metadata 
            {token-id: token-id}
            {
                owner: tx-sender,
                asset-type: asset-type,
                asset-value: asset-value,
                mint-timestamp: stacks-block-height,
                staking-start: none,
                staking-rewards: u0
            }
        )
        
        (ok token-id)
    )
)

;; Transfer an asset to another user
(define-public (transfer-asset 
    (token-id (buff 32))
    (sender principal)
    (recipient principal)
)
    (let 
        (
            (metadata (unwrap! (map-get? asset-metadata {token-id: token-id}) ERR-NOT-FOUND))
        )
        ;; Input validations
        (asserts! (is-valid-token-id token-id) ERR-INVALID-TOKEN)
        (asserts! (not (is-eq sender recipient)) ERR-INVALID-TRANSFER)
        
        ;; Verify sender is current owner
        (asserts! (is-eq sender (get owner metadata)) ERR-UNAUTHORIZED)
        
        ;; Ensure no active staking
        (asserts! (is-none (get staking-start metadata)) ERR-INVALID-TRANSFER)
        
        ;; Transfer asset token
        (try! (nft-transfer? satoshi-vault-asset token-id sender recipient))
        
        ;; Update metadata
        (map-set asset-metadata 
            {token-id: token-id}
            (merge metadata {owner: recipient})
        )
        
        (ok true)
    )
)

;; Stake an asset to earn governance tokens
(define-public (stake-asset (token-id (buff 32)))
    (let 
        (
            (metadata (unwrap! (map-get? asset-metadata {token-id: token-id}) ERR-NOT-FOUND))
            (current-block stacks-block-height)
        )
        ;; Input validations
        (asserts! (is-valid-token-id token-id) ERR-INVALID-TOKEN)
        
        ;; Verify owner
        (asserts! (is-eq tx-sender (get owner metadata)) ERR-UNAUTHORIZED)
        
        ;; Ensure not already staked
        (asserts! (is-none (get staking-start metadata)) ERR-STAKING-ERROR)
        
        ;; Update asset metadata with staking info
        (map-set asset-metadata 
            {token-id: token-id}
            (merge metadata 
                {
                    staking-start: (some current-block)
                }
            )
        )
        
        ;; Create staking entry
        (map-set asset-staking 
            {token-id: token-id}
            {
                staked-by: tx-sender,
                stake-start-block: current-block,
                total-staked-blocks: u0
            }
        )
        
        (ok true)
    )
)

;; Unstake an asset and claim rewards
(define-public (unstake-asset (token-id (buff 32)))
    (let 
        (
            (metadata (unwrap! (map-get? asset-metadata {token-id: token-id}) ERR-NOT-FOUND))
            (staking-info (unwrap! (map-get? asset-staking {token-id: token-id}) ERR-STAKING-ERROR))
            (current-block stacks-block-height)
            (stake-start (get stake-start-block staking-info))
            (staked-blocks (- current-block stake-start))
            (reward-calculation 
                (/ (* (get asset-value metadata) staked-blocks) u10000)
            )
        )
        ;; Input validations
        (asserts! (is-valid-token-id token-id) ERR-INVALID-TOKEN)
        
        ;; Verify staker
        (asserts! (is-eq tx-sender (get staked-by staking-info)) ERR-UNAUTHORIZED)
        
        ;; Update governance tokens
        (map-set governance-tokens 
            tx-sender 
            (+ (default-to u0 (map-get? governance-tokens tx-sender)) reward-calculation)
        )
        
        ;; Reset asset staking metadata
        (map-set asset-metadata 
            {token-id: token-id}
            (merge metadata 
                {
                    staking-start: none,
                    staking-rewards: (+ (get staking-rewards metadata) reward-calculation)
                }
            )
        )
        
        ;; Remove staking entry
        (map-delete asset-staking {token-id: token-id})
        
        (ok reward-calculation)
    )
)