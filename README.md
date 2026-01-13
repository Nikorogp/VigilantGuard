# VigilantGuard: Crypto Asset Price Anomaly Detector

I have designed **VigilantGuard** as a high-performance, decentralized statistical monitoring system built on the Stacks blockchain. This smart contract serves as a robust infrastructure layer for DeFi protocols, oracles, and institutional dashboards that require real-time validation of cryptocurrency price feeds.

By leveraging a sliding-window Z-Score methodology, I have built a system that identifies price manipulation, flash crashes, or reporting errors with mathematical precision, allowing downstream systems to pause or flag suspicious data before it impacts protocol solvency.

---

## Table of Contents

1. Core Features
2. Technical Architecture
3. Statistical Methodology
4. Private Functions (Internal Logic)
5. Public Functions (Write Operations)
6. Read-Only Functions (Data Queries)
7. Error Reference
8. Deployment & Configuration
9. Contribution Guidelines
10. License

---

## Core Features

* **Multi-Asset Support:** Track an unlimited number of registered assets (BTC, STX, ETH, etc.) within a single contract instance.
* **Statistical Analysis:** Real-time calculation of Mean and Standard Deviation over a rolling 10-period window.
* **Severity Classification:** Anomalies are automatically graded on a scale of 1 (Minor) to 5 (Critical) based on their Z-Score magnitude.
* **Role-Based Access Control (RBAC):** I implemented distinct permissions for the Contract Owner (administrative) and Authorized Reporters (data submission).
* **Fine-Grained Thresholds:** Override global detection parameters with asset-specific multipliers to account for different volatility profiles.
* **Historical Auditing:** Permanent on-chain records of detected anomalies, including the reporter identity and the exact statistical state at the time of detection.

---

## Technical Architecture

I have architected VigilantGuard to be both gas-efficient and mathematically sound within the constraints of the Clarity VM.

### Data Storage Strategy

* **Price History:** I utilize a map-based storage system that tracks the rolling sum and sum of squares. This allows for  calculation of variance without iterating through the entire list every time a new price is submitted.
* **Registration:** Assets must be explicitly registered by the owner to prevent spam and ensure data quality.
* **Authorization:** A whitelist-only reporter system ensures that only trusted oracles or data providers can influence the statistical baseline.

### Precision & Scaling

To handle floating-point mathematics in Clarity, I implement a fixed-point system with a precision factor of `100`.

* A threshold of `u200` represents **2.00** standard deviations.
* Prices are expected to be pre-scaled (e.g., **$100.50** is submitted as `10050`).

---

## Statistical Methodology

The core of my detection engine relies on the **Standard Score (Z-Score)**.

### Calculation Logic

1. **Mean ():** The arithmetic average of the last  data points.
2. **Variance ():** Calculated using the formula:


3. **Standard Deviation ():** The square root of the variance.
4. **Anomaly Detection:** A price () is flagged if:



---

## Private Functions (Internal Logic)

These functions are the "engine room" of the contract. I have kept them private to ensure that the complex statistical calculations cannot be tampered with or triggered out of sequence.

### calculate-mean

* **Purpose:** Retrieves the running sum and count for a specific `asset-id`.
* **Logic:** It performs a safety check against `MIN-DATA-POINTS`. If the history is too shallow, it returns an error to prevent skewed averages from triggering false positives.
* **Return:** A `uint` representing the average price scaled by the contract precision.

### calculate-std-deviation

* **Purpose:** Computes the volatility metric (Standard Deviation) for an asset.
* **Logic:** This is the most computationally intensive part of the contract. I use the "Computational Formula for Variance" to avoid storing every individual price in memory during the math phase. It uses the `sqrti` (integer square root) function to find the standard deviation from the variance.
* **Safety:** Includes an underflow check (`>= sum-sq (* mean-squared price-count)`) to ensure that rounding errors in fixed-point math don't cause a contract crash.

### is-anomaly

* **Purpose:** The final gatekeeper that determines if a price is "strange."
* **Logic:** It calculates the absolute difference between the current price and the mean. It then compares this to the `threshold-value` (which is standard deviation multiplied by the allowed sensitivity).
* **Return:** A simple `boolean` (true/false).

### calculate-severity

* **Purpose:** Assigns a "Danger Level" to an anomaly.
* **Logic:** I built a tiered branching logic based on the Z-score.
* **Level 5:** Price is > 5 standard deviations away (Black Swan event).
* **Level 1:** Price is within 2 standard deviations (Minor noise).



### update-price-history

* **Purpose:** Commits the new data point to the blockchain state.
* **Logic:** It updates five different variables simultaneously: the price list (as a `max-len 10` list), the total count, the running sum, the sum of squares, and the timestamp.

---

## Public Functions (Write Operations)

These are the entry points for users and admins. I have protected these with `asserts!` statements to ensure only the right people can call them.

### Administrative Actions

* **initialize-reporter:** I designed this as a "one-click" setup for the contract deployer to start reporting data immediately.
* **add-reporter / remove-reporter:** These allow the `CONTRACT-OWNER` to manage a decentralized network of trusted price oracles.
* **register-asset:** No data can be submitted for an asset (like "STX" or "BTC") until the owner has formally registered it. This prevents "dust" assets from clogging the contract maps.
* **set-asset-threshold:** This is a powerful tool for tuning. High-cap assets like BTC might need a lower threshold (e.g., 2.0), while micro-cap assets might need a 4.0 threshold to account for natural volatility.

### Operational Actions

* **submit-price:** This is the primary "write" function. It validates the reporter's identity, checks the price bounds against `MAX-PRICE`, and updates the rolling statistics.
* **detect-and-report-anomaly:** This is the "All-in-One" function. I designed it to be the main integration point for external systems. It does not just update the price; it runs the full statistical suite and returns a detailed response object containing the `severity`, `deviation`, and a `message`.

---

## Read-Only Functions (Data Queries)

I provided these functions to allow front-end dashboards and other smart contracts to read the state of the system without spending STX on gas.

* **is-authorized-reporter:** Checks if a specific wallet has permission to feed data into the system.
* **get-price-history:** Returns the raw statistical data for an asset. Useful for external bots that want to perform their own off-chain modeling.
* **get-asset-info:** Returns the human-readable name and the block height at which the asset was first tracked.
* **get-total-anomalies:** Provides a "Global Stress Index"—showing how many total anomalies have been detected across all assets in the system's lifetime.

---

## Error Reference

| Code | Constant | Description |
| --- | --- | --- |
| `u100` | `ERR-NOT-AUTHORIZED` | Caller is not the owner or an authorized reporter. |
| `u101` | `ERR-ASSET-NOT-FOUND` | The requested asset has not been registered. |
| `u102` | `ERR-INVALID-PRICE` | Price is zero or exceeds the 10-million limit. |
| `u103` | `ERR-INSUFFICIENT-DATA` | Statistical analysis requires at least 5 prior data points. |
| `u104` | `ERR-ALREADY-REGISTERED` | The asset or reporter is already present in the system. |
| `u105` | `ERR-INVALID-THRESHOLD` | Custom thresholds must be between 1.00 (100) and 10.00 (1000). |

---

## Deployment & Configuration

I recommend following these steps for a production deployment:

1. **Deployment:** Deploy the contract using the Stacks CLI or Clarinet.
2. **Initialization:** Call `initialize-reporter` to authorize the deployer.
3. **Asset Setup:** Call `register-asset` for your primary pairs (e.g., "STX", "BTC").
4. **Priming:** Submit at least 5 "normal" price points via `submit-price` to establish a baseline mean and standard deviation.
5. **Integration:** Connect your off-chain monitoring tool to the `detect-and-report-anomaly` function.

---

## Contribution Guidelines

I welcome contributions from the community to enhance the statistical capabilities of VigilantGuard.

1. **Fork the Repository:** Create a feature branch.
2. **Test-Driven Development:** Ensure all new logic includes `.clar` unit tests using the Clarinet framework.
3. **Gas Optimization:** Provide a gas consumption analysis if your changes affect the `calculate-std-deviation` logic.
4. **Documentation:** Update the README if new public methods are added.

---

## License

**MIT License**

Copyright (c) 2026 VigilantGuard Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

Would you like me to generate a set of Clarinet unit tests to verify the severity level calculations for you?
