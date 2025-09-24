;; Clinical Trial Management Smart Contract
;; Manages clinical trials with patient consent tracking, data integrity, and regulatory compliance

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-unauthorized (err u100))
(define-constant err-not-found (err u101))
(define-constant err-invalid-status (err u102))
(define-constant err-invalid-consent (err u103))
(define-constant err-trial-closed (err u104))
(define-constant err-already-enrolled (err u105))
(define-constant err-invalid-data (err u106))

;; Data variables
(define-data-var trial-counter uint u0)
(define-data-var patient-counter uint u0)
(define-data-var adverse-event-counter uint u0)

;; Trial status options
(define-constant status-planning "PLANNING")
(define-constant status-recruiting "RECRUITING")
(define-constant status-active "ACTIVE")
(define-constant status-completed "COMPLETED")
(define-constant status-suspended "SUSPENDED")
(define-constant status-terminated "TERMINATED")

;; Consent types
(define-constant consent-full u1)
(define-constant consent-limited u2)
(define-constant consent-data-only u3)

;; Data maps
(define-map trials
  { trial-id: uint }
  { 
    name: (string-ascii 100),
    sponsor: principal,
    principal-investigator: principal,
    status: (string-ascii 20),
    protocol-hash: (buff 32),
    start-date: uint,
    end-date: (optional uint),
    max-participants: uint,
    current-participants: uint,
    phase: (string-ascii 10),
    therapeutic-area: (string-ascii 50),
    created-at: uint,
    regulatory-approval: bool
  }
)

(define-map trial-investigators
  { trial-id: uint, investigator: principal }
  { authorized: bool, role: (string-ascii 30), added-at: uint }
)

(define-map patients
  { patient-id: uint }
  {
    identifier-hash: (buff 32),
    enrolled-trials: (list 10 uint),
    consent-status: uint,
    consent-timestamp: uint,
    data-access-level: uint,
    demographics-hash: (buff 32),
    enrollment-date: uint,
    active: bool
  }
)

(define-map patient-consent
  { patient-id: uint, trial-id: uint }
  {
    consent-type: uint,
    given-at: uint,
    expires-at: (optional uint),
    withdrawn-at: (optional uint),
    consent-hash: (buff 32),
    witness: (optional principal),
    active: bool
  }
)

(define-map trial-data
  { trial-id: uint, patient-id: uint, data-point-id: uint }
  {
    data-hash: (buff 32),
    timestamp: uint,
    data-type: (string-ascii 30),
    recorded-by: principal,
    verified: bool,
    verification-timestamp: (optional uint)
  }
)

(define-map adverse-events
  { event-id: uint }
  {
    trial-id: uint,
    patient-id: uint,
    severity: (string-ascii 20),
    description-hash: (buff 32),
    reported-at: uint,
    reported-by: principal,
    resolved: bool,
    resolution-date: (optional uint),
    regulatory-reported: bool
  }
)

(define-map trial-compliance
  { trial-id: uint }
  {
    gcp-compliant: bool,
    fda-compliant: bool,
    ema-compliant: bool,
    last-audit-date: (optional uint),
    compliance-score: uint,
    violations: (list 20 (buff 32))
  }
)

;; Authorization functions
(define-private (is-contract-owner)
  (is-eq tx-sender contract-owner)
)

(define-private (is-trial-sponsor (trial-id uint))
  (match (map-get? trials { trial-id: trial-id })
    trial (is-eq tx-sender (get sponsor trial))
    false
  )
)

(define-private (is-authorized-investigator (trial-id uint))
  (match (map-get? trial-investigators { trial-id: trial-id, investigator: tx-sender })
    investigator (get authorized investigator)
    (is-trial-sponsor trial-id)
  )
)

;; Trial management functions
(define-public (create-trial 
  (name (string-ascii 100))
  (protocol-hash (buff 32))
  (max-participants uint)
  (phase (string-ascii 10))
  (therapeutic-area (string-ascii 50))
  (principal-investigator principal)
)
  (let 
    (
      (trial-id (+ (var-get trial-counter) u1))
      (current-time u1)
    )
    (begin
      (map-set trials
        { trial-id: trial-id }
        { 
          name: name,
          sponsor: tx-sender,
          principal-investigator: principal-investigator,
          status: status-planning,
          protocol-hash: protocol-hash,
          start-date: current-time,
          end-date: none,
          max-participants: max-participants,
          current-participants: u0,
          phase: phase,
          therapeutic-area: therapeutic-area,
          created-at: current-time,
          regulatory-approval: false
        }
      )
      
      ;; Add principal investigator to authorized investigators
      (map-set trial-investigators
        { trial-id: trial-id, investigator: principal-investigator }
        { authorized: true, role: "PRINCIPAL_INVESTIGATOR", added-at: current-time }
      )
      
      ;; Initialize compliance record
      (map-set trial-compliance
        { trial-id: trial-id }
        { 
          gcp-compliant: false,
          fda-compliant: false,
          ema-compliant: false,
          last-audit-date: none,
          compliance-score: u0,
          violations: (list)
        }
      )
      
      (var-set trial-counter trial-id)
      (ok trial-id)
    )
  )
)

(define-public (update-trial-status (trial-id uint) (new-status (string-ascii 20)))
  (begin
    (asserts! (is-authorized-investigator trial-id) err-unauthorized)
    (asserts! (is-some (map-get? trials { trial-id: trial-id })) err-not-found)
    
    (match (map-get? trials { trial-id: trial-id })
      trial
      (begin
        (map-set trials 
          { trial-id: trial-id }
          (merge trial { status: new-status })
        )
        (ok true)
      )
      err-not-found
    )
  )
)

(define-public (add-investigator (trial-id uint) (investigator principal) (role (string-ascii 30)))
  (begin
    (asserts! (is-trial-sponsor trial-id) err-unauthorized)
    (asserts! (is-some (map-get? trials { trial-id: trial-id })) err-not-found)
    
    (map-set trial-investigators
      { trial-id: trial-id, investigator: investigator }
      { authorized: true, role: role, added-at: u1 }
    )
    (ok true)
  )
)

;; Patient enrollment and consent functions
(define-public (enroll-patient
  (identifier-hash (buff 32))
  (demographics-hash (buff 32))
  (trial-id uint)
  (consent-type uint)
  (consent-hash (buff 32))
)
  (begin
    (asserts! (is-authorized-investigator trial-id) err-unauthorized)
    
    (match (map-get? trials { trial-id: trial-id })
      trial
      (begin
        (asserts! (< (get current-participants trial) (get max-participants trial)) err-trial-closed)
        (asserts! (is-eq (get status trial) status-recruiting) err-invalid-status)
        
        (let 
          (
            (patient-id (+ (var-get patient-counter) u1))
            (current-time u1)
          )
          
          ;; Create patient record
          (map-set patients
            { patient-id: patient-id }
            {
              identifier-hash: identifier-hash,
              enrolled-trials: (list trial-id),
              consent-status: consent-type,
              consent-timestamp: current-time,
              data-access-level: consent-type,
              demographics-hash: demographics-hash,
              enrollment-date: current-time,
              active: true
            }
          )
          
          ;; Record consent
          (map-set patient-consent
            { patient-id: patient-id, trial-id: trial-id }
            {
              consent-type: consent-type,
              given-at: current-time,
              expires-at: none,
              withdrawn-at: none,
              consent-hash: consent-hash,
              witness: (some tx-sender),
              active: true
            }
          )
          
          ;; Update trial participant count
          (map-set trials
            { trial-id: trial-id }
            (merge trial { current-participants: (+ (get current-participants trial) u1) })
          )
          
          (var-set patient-counter patient-id)
          (ok patient-id)
        )
      )
      err-not-found
    )
  )
)

(define-public (withdraw-consent (patient-id uint) (trial-id uint))
  (begin
    (match (map-get? patient-consent { patient-id: patient-id, trial-id: trial-id })
      consent
      (begin
        (map-set patient-consent
          { patient-id: patient-id, trial-id: trial-id }
          (merge consent { 
            withdrawn-at: (some u1),
            active: false 
          })
        )
        (ok true)
      )
      err-not-found
    )
  )
)

;; Data recording functions
(define-public (record-trial-data
  (trial-id uint)
  (patient-id uint)
  (data-hash (buff 32))
  (data-type (string-ascii 30))
)
  (begin
    (asserts! (is-authorized-investigator trial-id) err-unauthorized)
    (asserts! (is-consent-active patient-id trial-id) err-invalid-consent)
    
    (let ((data-point-id (+ u1 (get-next-data-point-id trial-id patient-id))))
      (map-set trial-data
        { trial-id: trial-id, patient-id: patient-id, data-point-id: data-point-id }
        {
          data-hash: data-hash,
          timestamp: u1,
          data-type: data-type,
          recorded-by: tx-sender,
          verified: false,
          verification-timestamp: none
        }
      )
      (ok data-point-id)
    )
  )
)

(define-public (verify-trial-data
  (trial-id uint)
  (patient-id uint)
  (data-point-id uint)
)
  (begin
    (asserts! (is-authorized-investigator trial-id) err-unauthorized)
    
    (match (map-get? trial-data { trial-id: trial-id, patient-id: patient-id, data-point-id: data-point-id })
      data-point
      (begin
        (map-set trial-data
          { trial-id: trial-id, patient-id: patient-id, data-point-id: data-point-id }
          (merge data-point {
            verified: true,
            verification-timestamp: (some u1)
          })
        )
        (ok true)
      )
      err-not-found
    )
  )
)

;; Adverse event reporting
(define-public (report-adverse-event
  (trial-id uint)
  (patient-id uint)
  (severity (string-ascii 20))
  (description-hash (buff 32))
)
  (begin
    (asserts! (is-authorized-investigator trial-id) err-unauthorized)
    
    (let 
      (
        (event-id (+ (var-get adverse-event-counter) u1))
        (current-time u1)
      )
      (map-set adverse-events
        { event-id: event-id }
        {
          trial-id: trial-id,
          patient-id: patient-id,
          severity: severity,
          description-hash: description-hash,
          reported-at: current-time,
          reported-by: tx-sender,
          resolved: false,
          resolution-date: none,
          regulatory-reported: false
        }
      )
      
      (var-set adverse-event-counter event-id)
      (ok event-id)
    )
  )
)

;; Helper functions
(define-private (is-consent-active (patient-id uint) (trial-id uint))
  (match (map-get? patient-consent { patient-id: patient-id, trial-id: trial-id })
    consent (get active consent)
    false
  )
)

(define-private (get-next-data-point-id (trial-id uint) (patient-id uint))
  ;; Simple implementation - in production, this would track per patient/trial
  u0
)

;; Read-only functions
(define-read-only (get-trial (trial-id uint))
  (map-get? trials { trial-id: trial-id })
)

(define-read-only (get-patient (patient-id uint))
  (map-get? patients { patient-id: patient-id })
)

(define-read-only (get-patient-consent (patient-id uint) (trial-id uint))
  (map-get? patient-consent { patient-id: patient-id, trial-id: trial-id })
)

(define-read-only (get-trial-data (trial-id uint) (patient-id uint) (data-point-id uint))
  (map-get? trial-data { trial-id: trial-id, patient-id: patient-id, data-point-id: data-point-id })
)

(define-read-only (get-adverse-event (event-id uint))
  (map-get? adverse-events { event-id: event-id })
)

(define-read-only (get-trial-compliance (trial-id uint))
  (map-get? trial-compliance { trial-id: trial-id })
)

(define-read-only (get-trial-counter)
  (var-get trial-counter)
)

(define-read-only (get-patient-counter)
  (var-get patient-counter)
)

(define-read-only (is-investigator-authorized (trial-id uint) (investigator principal))
  (match (map-get? trial-investigators { trial-id: trial-id, investigator: investigator })
    auth (get authorized auth)
    false
  )
)
