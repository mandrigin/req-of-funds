# Gateway.fm Fintech Strategy Research Plan

**Objective:** Produce an implementation-oriented strategy spec for Gateway.fm to win the fintech/neobank market in 2026-2027.

**Goals:**
- Onboard ≥20 paying fintech/neobank clients
- Maintain burn-rate discipline
- Scale credibly for regulated institutions

---

## Current Understanding (Research Completed)

### Gateway.fm Profile
- **Founded:** 2021, Stavanger, Norway
- **Founders:** Igor Mandrigin, Cuautemoc Weber (CEO)
- **Funding:** $4.6M seed (Feb 2023) led by Lemniscap
- **Investors:** Lemniscap, CMT Digital, Folius Ventures, L1D, Hub71, others
- **Key Products:**
  - Presto (RaaS platform) - 35+ customizations, L2/L3 support
  - RPC endpoints - 30K RPS, 99.99% uptime
  - Shared Prover (ZK proof generation)
  - Node service with staking automation
  - Indexer, Oracle, Account Abstraction
- **Certifications:** ISO/SOC certified, PwC audited
- **Partners:** Polygon, Gnosis, Erigon, NEAR, Lido, Ethereum Foundation
- **Customers:** Haust Network, Gnosis Chain, Polygon Labs, Celestia Labs, Linea, Status Network
- **Tech:** 500 MGas/s peak throughput, 250ms block time, EVM-compatible

### RaaS Competitive Landscape
| Provider | Stack Support | Differentiation | Target Market |
|----------|--------------|-----------------|---------------|
| **Gateway.fm** | Polygon CDK, OP, Arbitrum | 35+ configs, enterprise SLA, ISO/SOC | Enterprise, regulated |
| **Conduit** | OP Stack, Arbitrum Orbit | Fast deployment, SMB-focused | Small/medium teams |
| **Caldera** | OP Stack | Performance optimized | Gaming, social apps |
| **Alchemy** | Multiple | 99.999% uptime, monitoring | High-reliability needs |
| **AltLayer** | Flexible | Restaked rollups, dynamic scaling | DeFi, custom AVSes |
| **Gelato** | Multiple | Market leader, full-stack | General market |

**Market size:** $89.2M (2025) → $354M (2032), 20.5% CAGR

### Fintech/Neobank Market Reality (2026)
- **Regulatory:** MiCA (EU), GENIUS Act (US stablecoins), DORA (IT resilience)
- **Key Players Moving In:** Stripe (Tempo L1), Revolut (MiCA licensed), Circle, Paxos
- **OCC Trust Charters:** BitGo, Circle, Fidelity Digital, Paxos, Ripple (Dec 2025)
- **Buyer Concerns:** Compliance, uptime, vendor risk, KYC/AML, audit trails
- **Infrastructure Decisions:** Build vs partner, proprietary vs established players

---

## Research Tasks by Strategy Section

### Section 0: Executive Summary
*Synthesize from other sections - no dedicated research needed*

---

### Section 1: Rapid Outside-In Assessment

#### Task 1.1: Gateway.fm Deep Dive
- [ ] **Interview/analyze founder backgrounds** - Igor Mandrigin (Erigon contributor), Cuautemoc Weber
- [ ] **Map technical contributions** - Erigon development, Polygon CDK 30x throughput improvement
- [ ] **Assess current customer base** - nature of relationships, contract types, retention
- [ ] **Analyze burn rate** - $4.6M seed in Feb 2023, 3 years runway assessment

**Research sources:**
- LinkedIn profiles for team analysis
- GitHub contributions (Erigon, Polygon CDK)
- Customer case studies on website
- Crunchbase/Tracxn for financial signals

#### Task 1.2: Structural Position Analysis
- [ ] **Europe-based advantage** - Norway HQ, GDPR native, MiCA proximity
- [ ] **ISO/SOC certification value** - how rare among RaaS competitors
- [ ] **Partnership depth** - Ethereum Foundation, Polygon Labs relationships

---

### Section 2: Fintech & Neobank Buyer Reality

#### Task 2.1: Buyer Archetype Research
| Research Target | Method | Questions |
|----------------|--------|-----------|
| **Neobanks (Revolut-tier)** | Public statements, job postings | Infra priorities, build vs buy signals |
| **Mid-tier fintechs** | LinkedIn outreach, conference talks | Vendor selection criteria |
| **Crypto-native fintechs** | Discord/Twitter analysis | Pain points with current infra |
| **Traditional banks with digital units** | Public procurement documents | Compliance requirements |

- [ ] Analyze Revolut's infrastructure choices (MiCA-licensed, crypto-native)
- [ ] Research neobank infrastructure patterns (Monzo, N26, Chime tech stacks)
- [ ] Identify 10 mid-market fintechs exploring blockchain (Series A-C)
- [ ] Map traditional bank blockchain pilots (JP Morgan, Goldman, Visa)

#### Task 2.2: Sales Cycle Analysis
- [ ] **Enterprise fintech sales cycle research** - typical 6-18 months
- [ ] **Procurement stakeholders** - CTO, CISO, Compliance, Procurement
- [ ] **Vendor risk assessment criteria** - SOC2, uptime SLAs, incident response
- [ ] **Kill points** - where deals typically fail (compliance, integration, pricing)

**Research sources:**
- Fintech conference recordings (Money20/20, Finovate)
- LinkedIn job postings for "blockchain infrastructure" hires
- RFP templates from public procurement

---

### Section 3: Competitive Landscape

#### Task 3.1: Direct Competitor Deep Dive
For each competitor (Conduit, Caldera, Alchemy, AltLayer, Gelato):
- [ ] **Pricing models** - published tiers, enterprise pricing signals
- [ ] **Enterprise customers** - who they publicly claim
- [ ] **Certifications** - SOC2, ISO27001, PCI-DSS
- [ ] **Technical limitations** - support matrices, stack constraints
- [ ] **Sales motion** - self-serve vs enterprise, SDR presence

#### Task 3.2: Indirect Competition Analysis
- [ ] **"Do nothing" option** - why fintechs stay on traditional rails
- [ ] **Internal build** - when companies choose to build own L2
- [ ] **TradFi infrastructure** - AWS, Azure blockchain services
- [ ] **Non-blockchain alternatives** - traditional database solutions

#### Task 3.3: Positioning Matrix
- [ ] Build win/lose matrix by use case
- [ ] Identify where Gateway.fm has credible advantage
- [ ] Map "no-go" zones (avoid competing)

---

### Section 4: Product Strategy

#### Task 4.1: Product Bet Validation
- [ ] **Core offering analysis** - which products drive revenue vs marketing
- [ ] **Presto utilization** - how many production rollups launched
- [ ] **RPC business health** - competitive dynamics with Alchemy/Infura
- [ ] **Kill candidates** - products with low usage/high maintenance

#### Task 4.2: Fintech-Specific Requirements
| Requirement | Current State | Gap Analysis |
|------------|---------------|--------------|
| **Compliance** | ISO/SOC | PCI-DSS, SOX? |
| **Reliability** | 99.99% | 99.999% needed? |
| **Control** | ? | On-prem option? |
| **Interop** | EVM | Fiat rails? |

- [ ] Map MiCA compliance requirements to product features
- [ ] Assess DORA (EU IT resilience) implications
- [ ] Research SOX compliance needs for US market

#### Task 4.3: Packaging & Pricing Research
- [ ] Analyze competitor pricing (public tiers)
- [ ] Research fintech infrastructure spend benchmarks
- [ ] Identify expansion revenue levers (usage-based, seats, features)

---

### Section 5: Go-To-Market Strategy

#### Task 5.1: Target Segment Prioritization
- [ ] **Tier 1 targets** - List 20 specific company names
- [ ] **Geographic focus** - EU (MiCA) vs US (post-GENIUS) vs APAC
- [ ] **Vertical focus** - payments, lending, trading, banking

#### Task 5.2: GTM Motion Analysis
- [ ] **Current motion** - founder-led vs sales team
- [ ] **Partner leverage** - Polygon, Gnosis referral potential
- [ ] **Channel analysis** - direct sales vs channel vs PLG

#### Task 5.3: Proof Strategy
- [ ] **Case study inventory** - existing customer stories
- [ ] **Reference customers** - who would do calls
- [ ] **Certification gap** - what buyers need to see
- [ ] **Trust manufacturing** - analyst reports, awards, press

---

### Section 6: Sales Strategy

#### Task 6.1: Sales Motion Design
- [ ] **Ideal customer profile** - company size, stage, tech stack
- [ ] **Discovery questions** - what qualifies/disqualifies
- [ ] **Demo flow** - what to show fintech buyers
- [ ] **POC structure** - how to de-risk for buyers

#### Task 6.2: Sales Team Requirements
- [ ] **Current team analysis** - who sells today
- [ ] **Role gaps** - AE, SE, CSM needs
- [ ] **Hiring priority** - sequence of hires

#### Task 6.3: Deal Dynamics
- [ ] **Common objections** - compliance, vendor risk, pricing
- [ ] **Stall reasons** - why deals pause
- [ ] **Unblock tactics** - what moves deals forward

---

### Section 7: Marketing Strategy

#### Task 7.1: Narrative Development
- [ ] **Problem statement** - what problem does Gateway.fm solve for fintechs
- [ ] **Differentiation** - why not Alchemy/Conduit
- [ ] **Proof points** - credibility anchors

#### Task 7.2: Channel Analysis
- [ ] **Conference ROI** - which events matter (Money20/20, EthCC, Consensus)
- [ ] **Content that converts** - what regulated buyers consume
- [ ] **Partnership marketing** - co-marketing with Polygon, Gnosis

#### Task 7.3: Trust Building
- [ ] **Analyst relations** - Gartner, Forrester, Messari coverage
- [ ] **Media strategy** - fintech vs crypto press
- [ ] **Thought leadership** - topics that resonate with buyers

---

### Section 8: Hiring & Org Design

#### Task 8.1: Critical Hire Analysis
| Role | Priority | Why |
|------|----------|-----|
| Head of Sales (Fintech) | P0 | Enterprise motion |
| Solutions Engineer | P0 | Technical sales |
| Compliance Lead | P1 | Regulated buyers |
| Customer Success | P1 | Expansion revenue |

- [ ] Research comparable company org structures
- [ ] Benchmark compensation for fintech sales roles
- [ ] Identify talent pools (ex-Alchemy, ex-Stripe, ex-Revolut)

#### Task 8.2: Org Design Principles
- [ ] **Current team structure** - who does what
- [ ] **Growth bottlenecks** - where scaling breaks
- [ ] **Burn alignment** - compensation vs targets

---

### Section 9: Financial & Burn Discipline

#### Task 9.1: Cost Analysis
- [ ] **Engineering costs** - team size, compensation
- [ ] **Infrastructure costs** - cloud, node operations
- [ ] **Sales/marketing spend** - current allocation
- [ ] **Runway calculation** - months at current burn

#### Task 9.2: Unit Economics
- [ ] **ACV benchmarks** - RaaS contract values
- [ ] **CAC estimates** - cost per enterprise customer
- [ ] **LTV projections** - expansion, churn assumptions

---

### Section 10: Execution Risks

#### Task 10.1: Risk Inventory
- [ ] **Market risks** - crypto winter, regulatory shifts
- [ ] **Competitive risks** - price war, consolidation
- [ ] **Execution risks** - hiring, technical delivery
- [ ] **Financial risks** - runway, fundraising environment

#### Task 10.2: Early Warning Signals
- [ ] Define leading indicators for each risk
- [ ] Establish monitoring cadence

---

### Section 11: 90-Day Action Plan

*Synthesize from above sections*
- [ ] Week 1-2: Validation priorities
- [ ] Week 3-4: Key decisions
- [ ] Week 5-12: Execution sprint

---

## Immediate Research Actions (Dispatchable)

### Parallel Research Workstreams

**Workstream A: Competitor Intelligence**
```
Research Conduit, Caldera, Alchemy, AltLayer pricing and enterprise positioning.
Deliverable: Competitive pricing matrix with enterprise tier details.
```

**Workstream B: Fintech Buyer Interviews**
```
Compile list of 20 fintech CTOs/infrastructure leads from LinkedIn.
Research their public statements on blockchain infrastructure.
Deliverable: Buyer persona document with quotes and preferences.
```

**Workstream C: Regulatory Requirements**
```
Deep dive on MiCA, DORA, GENIUS Act requirements for blockchain infra.
Deliverable: Compliance checklist for fintech-focused RaaS.
```

**Workstream D: Case Study Development**
```
Analyze existing Gateway.fm customers (Haust, Gnosis, Polygon).
Research their use cases and public statements.
Deliverable: 3 draft case study outlines.
```

**Workstream E: Pricing Strategy**
```
Research enterprise infrastructure pricing models.
Analyze fintech infrastructure budgets.
Deliverable: Pricing framework recommendation.
```

---

## Research Sources

### Primary Sources
- Gateway.fm website, blog, documentation
- LinkedIn (team, customers, prospects)
- GitHub (technical contributions)
- Conference recordings (EthCC, Consensus, Money20/20)
- Job postings (Gateway.fm and competitors)

### Secondary Sources
- Analyst reports (Messari, Gartner, Forrester)
- Press coverage (The Block, CoinDesk, Fintech Global)
- Crunchbase, PitchBook (funding, valuations)
- Regulatory documents (EU, US, Singapore)

### Competitor Sources
- Conduit: conduit.xyz
- Caldera: caldera.xyz
- Alchemy: alchemy.com/rollups
- AltLayer: altlayer.io
- Gelato: gelato.network

---

## Output Format

Final strategy spec will follow the exact format from the source spec:
- Section 0-11 as specified
- Bullets, tables, checklists preferred
- No marketing language
- Explicit assumptions and unknowns
- Concrete recommendations

---

## Timeline Estimate

*Note: No time estimates per Mayor guidelines - work proceeds as resources allow*

Priority order:
1. Competitor intelligence (informs positioning)
2. Buyer reality research (informs GTM)
3. Product gap analysis (informs roadmap)
4. Financial modeling (informs hiring)
5. Risk assessment (informs guardrails)
6. Synthesis into final document
