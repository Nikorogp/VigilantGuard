;; Crypto Asset Price Anomaly Detector
;; 
;; This smart contract detects anomalies in cryptocurrency asset prices by tracking
;; historical price data, calculating statistical thresholds, and flagging unusual
;; price movements. It supports multiple assets, allows authorized reporters to submit
;; price data, and enables users to query anomaly status and historical trends.
;; The contract uses z-score methodology to identify price deviations from historical means.

;; constants

;; Error codes for various failure conditions
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-ASSET-NOT-FOUND (err u101))
(define-constant ERR-INVALID-PRICE (err u102))
(define-constant ERR-INSUFFICIENT-DATA (err u103))
(define-constant ERR-ALREADY-REGISTERED (err u104))
(define-constant ERR-INVALID-THRESHOLD (err u105))
(define-constant ERR-INVALID-DEVIATION (err u106))

;; Contract owner who has administrative privileges
(define-constant CONTRACT-OWNER tx-sender)

;; Statistical thresholds for anomaly detection
;; Threshold multiplier for z-score (2 = 2 standard deviations)
(define-constant ANOMALY-THRESHOLD u200) ;; Represents 2.00 in fixed point (divide by 100)
(define-constant MIN-DATA-POINTS u5) ;; Minimum samples needed for statistical analysis
(define-constant MAX-PRICE u1000000000) ;; Maximum allowed price (10 million with 2 decimals)
(define-constant PRECISION u100) ;; Fixed point precision for calculations

;; data maps and vars

;; Tracks authorized price reporters who can submit price data
(define-map authorized-reporters principal bool)

;; Stores price history for each asset (asset-id -> list of recent prices)
;; We store the last 10 prices for rolling statistics
(define-map price-history 
  { asset-id: (string-ascii 20) }
  { 
    prices: (list 10 uint),
    count: uint,
    sum: uint,
    sum-squares: uint,
    last-price: uint,
    last-update: uint
  }
)

;; Records anomaly events when detected
(define-map anomaly-records
  { asset-id: (string-ascii 20), block-height: uint }
  {
    price: uint,
    mean: uint,
    deviation: uint,
    severity: uint,
    reporter: principal
  }
)

;; Tracks registered assets in the system
(define-map registered-assets
  { asset-id: (string-ascii 20) }
  { 
    name: (string-ascii 50),
    registered-at: uint,
    active: bool
  }
)

;; Counter for total anomalies detected across all assets
(define-data-var total-anomalies-detected uint u0)

;; Custom threshold multipliers per asset (allows fine-tuning)
(define-map asset-thresholds
  { asset-id: (string-ascii 20) }
  { threshold-multiplier: uint }
)

;; private functions

;; Calculates the mean (average) of stored prices for an asset
;; @param asset-id: The identifier of the asset
;; @returns: (response uint uint) - The mean price or error if insufficient data
(define-private (calculate-mean (asset-id (string-ascii 20)))
  (let
    (
      (history-data (unwrap! (map-get? price-history { asset-id: asset-id }) ERR-ASSET-NOT-FOUND))
      (price-count (get count history-data))
      (price-sum (get sum history-data))
    )
    (if (< price-count MIN-DATA-POINTS)
      ERR-INSUFFICIENT-DATA
      (ok (/ price-sum price-count))
    )
  )
)

;; Calculates variance and standard deviation for an asset's price history
;; @param asset-id: The identifier of the asset
;; @param mean-price: The pre-calculated mean price
;; @returns: (response uint uint) - Standard deviation or error
(define-private (calculate-std-deviation (asset-id (string-ascii 20)) (mean-price uint))
  (let
    (
      (history-data (unwrap! (map-get? price-history { asset-id: asset-id }) ERR-ASSET-NOT-FOUND))
      (price-count (get count history-data))
      (sum-sq (get sum-squares history-data))
      (mean-squared (* mean-price mean-price))
      (variance-numerator (if (>= sum-sq (* mean-squared price-count))
                             (- sum-sq (* mean-squared price-count))
                             u0))
      (variance (/ variance-numerator price-count))
      (std-dev (sqrti variance))
    )
    (ok std-dev)
  )
)

;; Determines if a price represents an anomaly based on z-score
;; @param current-price: The price to evaluate
;; @param mean-price: The historical mean
;; @param std-dev: The standard deviation
;; @param threshold: The threshold multiplier
;; @returns: bool - True if anomaly detected
(define-private (is-anomaly (current-price uint) (mean-price uint) (std-dev uint) (threshold uint))
  (let
    (
      (deviation (if (> current-price mean-price)
                    (- current-price mean-price)
                    (- mean-price current-price)))
      (threshold-value (/ (* std-dev threshold) PRECISION))
    )
    (> deviation threshold-value)
  )
)

;; Calculates anomaly severity level (1-5) based on deviation magnitude
;; @param deviation: The absolute price deviation from mean
;; @param std-dev: The standard deviation
;; @returns: uint - Severity level (1=low, 5=critical)
(define-private (calculate-severity (deviation uint) (std-dev uint))
  (let
    (
      (z-score (if (> std-dev u0) (/ (* deviation PRECISION) std-dev) u0))
    )
    (if (>= z-score u500) u5  ;; > 5 std devs
      (if (>= z-score u400) u4  ;; > 4 std devs
        (if (>= z-score u300) u3  ;; > 3 std devs
          (if (>= z-score u200) u2  ;; > 2 std devs
            u1))))  ;; <= 2 std devs
  )
)

;; Updates the rolling price history when a new price is submitted
;; @param asset-id: The identifier of the asset
;; @param new-price: The new price to add
;; @returns: (response bool uint) - Success or error
(define-private (update-price-history (asset-id (string-ascii 20)) (new-price uint))
  (let
    (
      (history-opt (map-get? price-history { asset-id: asset-id }))
      (current-history (default-to 
        { prices: (list), count: u0, sum: u0, sum-squares: u0, last-price: u0, last-update: u0 }
        history-opt))
      (current-prices (get prices current-history))
      (current-count (get count current-history))
      (current-sum (get sum current-history))
      (current-sum-sq (get sum-squares current-history))
      (new-sum (+ current-sum new-price))
      (new-sum-sq (+ current-sum-sq (* new-price new-price)))
      (updated-prices (unwrap! (as-max-len? (append current-prices new-price) u10) ERR-INVALID-PRICE))
      (updated-count (+ current-count u1))
    )
    (map-set price-history
      { asset-id: asset-id }
      {
        prices: updated-prices,
        count: updated-count,
        sum: new-sum,
        sum-squares: new-sum-sq,
        last-price: new-price,
        last-update: block-height
      }
    )
    (ok true)
  )
)

;; public functions

;; Registers the contract deployer as an authorized reporter
;; @returns: (response bool uint) - Success or already registered error
(define-public (initialize-reporter)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (is-none (map-get? authorized-reporters CONTRACT-OWNER)) ERR-ALREADY-REGISTERED)
    (map-set authorized-reporters CONTRACT-OWNER true)
    (ok true)
  )
)

;; Adds a new authorized reporter who can submit price data
;; @param reporter: The principal to authorize
;; @returns: (response bool uint) - Success or error
(define-public (add-reporter (reporter principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (map-set authorized-reporters reporter true)
    (ok true)
  )
)

;; Removes authorization from a reporter
;; @param reporter: The principal to deauthorize
;; @returns: (response bool uint) - Success or error
(define-public (remove-reporter (reporter principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (map-delete authorized-reporters reporter)
    (ok true)
  )
)

;; Registers a new asset for price tracking and anomaly detection
;; @param asset-id: Unique identifier for the asset (e.g., "BTC", "ETH")
;; @param asset-name: Human-readable name of the asset
;; @returns: (response bool uint) - Success or already registered error
(define-public (register-asset (asset-id (string-ascii 20)) (asset-name (string-ascii 50)))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (is-none (map-get? registered-assets { asset-id: asset-id })) ERR-ALREADY-REGISTERED)
    (map-set registered-assets
      { asset-id: asset-id }
      { name: asset-name, registered-at: block-height, active: true }
    )
    (ok true)
  )
)

;; Submits a new price data point for an asset and checks for anomalies
;; @param asset-id: The identifier of the asset
;; @param price: The current price (scaled by PRECISION, e.g., 10050 = 100.50)
;; @returns: (response bool uint) - Success or error if unauthorized/invalid
(define-public (submit-price (asset-id (string-ascii 20)) (price uint))
  (let
    (
      (is-reporter (default-to false (map-get? authorized-reporters tx-sender)))
      (asset-exists (is-some (map-get? registered-assets { asset-id: asset-id })))
    )
    (asserts! is-reporter ERR-NOT-AUTHORIZED)
    (asserts! asset-exists ERR-ASSET-NOT-FOUND)
    (asserts! (and (> price u0) (<= price MAX-PRICE)) ERR-INVALID-PRICE)
    
    (unwrap! (update-price-history asset-id price) ERR-INVALID-PRICE)
    (ok true)
  )
)

;; Sets a custom anomaly detection threshold for a specific asset
;; @param asset-id: The identifier of the asset
;; @param threshold: The threshold multiplier (scaled by PRECISION)
;; @returns: (response bool uint) - Success or error
(define-public (set-asset-threshold (asset-id (string-ascii 20)) (threshold uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (is-some (map-get? registered-assets { asset-id: asset-id })) ERR-ASSET-NOT-FOUND)
    (asserts! (and (>= threshold u100) (<= threshold u1000)) ERR-INVALID-THRESHOLD)
    (map-set asset-thresholds { asset-id: asset-id } { threshold-multiplier: threshold })
    (ok true)
  )
)

;; read-only functions

;; Checks if a principal is an authorized reporter
;; @param reporter: The principal to check
;; @returns: bool - True if authorized
(define-read-only (is-authorized-reporter (reporter principal))
  (default-to false (map-get? authorized-reporters reporter))
)

;; Retrieves the price history data for an asset
;; @param asset-id: The identifier of the asset
;; @returns: (optional {...}) - The price history or none
(define-read-only (get-price-history (asset-id (string-ascii 20)))
  (map-get? price-history { asset-id: asset-id })
)

;; Retrieves asset registration information
;; @param asset-id: The identifier of the asset
;; @returns: (optional {...}) - The asset info or none
(define-read-only (get-asset-info (asset-id (string-ascii 20)))
  (map-get? registered-assets { asset-id: asset-id })
)

;; Gets the total count of anomalies detected system-wide
;; @returns: uint - Total anomalies detected
(define-read-only (get-total-anomalies)
  (var-get total-anomalies-detected)
)

;; Advanced anomaly detection and reporting function
;; This comprehensive function performs real-time anomaly detection by:
;; 1. Validating the asset and reporter authorization
;; 2. Calculating statistical measures (mean, standard deviation)
;; 3. Comparing current price against historical thresholds
;; 4. Recording anomaly events with severity classification
;; 5. Providing detailed anomaly analysis for monitoring systems
;; @param asset-id: The identifier of the crypto asset to analyze
;; @param current-price: The latest price point to evaluate for anomalies
;; @returns: (response {...} uint) - Detailed anomaly report or error code
(define-public (detect-and-report-anomaly (asset-id (string-ascii 20)) (current-price uint))
  (let
    (
      ;; Verify reporter authorization and asset existence
      (is-reporter (default-to false (map-get? authorized-reporters tx-sender)))
      (asset-exists (is-some (map-get? registered-assets { asset-id: asset-id })))
      
      ;; Retrieve or calculate statistical measures
      (mean-result (calculate-mean asset-id))
      (mean-price (unwrap! mean-result (ok { anomaly-detected: false, severity: u0, message: "insufficient-data" })))
      (std-dev-result (calculate-std-deviation asset-id mean-price))
      (std-dev (unwrap! std-dev-result (ok { anomaly-detected: false, severity: u0, message: "calculation-error" })))
      
      ;; Get custom threshold or use default
      (custom-threshold (map-get? asset-thresholds { asset-id: asset-id }))
      (threshold (default-to ANOMALY-THRESHOLD (get threshold-multiplier custom-threshold)))
      
      ;; Calculate price deviation metrics
      (price-deviation (if (> current-price mean-price)
                          (- current-price mean-price)
                          (- mean-price current-price)))
      (anomaly-detected (is-anomaly current-price mean-price std-dev threshold))
      (severity-level (calculate-severity price-deviation std-dev))
    )
    ;; Validate inputs and authorization
    (asserts! is-reporter ERR-NOT-AUTHORIZED)
    (asserts! asset-exists ERR-ASSET-NOT-FOUND)
    (asserts! (and (> current-price u0) (<= current-price MAX-PRICE)) ERR-INVALID-PRICE)
    
    ;; Record anomaly event if detected
    (if anomaly-detected
      (begin
        (map-set anomaly-records
          { asset-id: asset-id, block-height: block-height }
          {
            price: current-price,
            mean: mean-price,
            deviation: price-deviation,
            severity: severity-level,
            reporter: tx-sender
          }
        )
        (var-set total-anomalies-detected (+ (var-get total-anomalies-detected) u1))
        (ok { 
          anomaly-detected: true, 
          severity: severity-level, 
          message: "anomaly-recorded",
          deviation: price-deviation,
          mean: mean-price,
          threshold: threshold
        })
      )
      (ok { 
        anomaly-detected: false, 
        severity: u0, 
        message: "normal-price-range",
        deviation: price-deviation,
        mean: mean-price,
        threshold: threshold
      })
    )
  )
)


