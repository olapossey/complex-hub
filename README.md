# Complex Hub Smart Contract

A comprehensive Clarity smart contract implementing multiple DeFi and DAO functionalities on the Stacks blockchain.

## Features

- **Staking System**: Stake and unstake STX tokens with rewards distribution
- **DAO Governance**: Create and vote on proposals with stake-weighted voting
- **Reputation System**: Track and update user reputation scores
- **Lending Platform**: NFT-collateralized loans with funding and repayment
- **Insurance System**: Create insurance pools, buy policies, and process claims
- **Prediction Markets**: Create markets, place bets, and claim winnings
- **Built-in Treasury Management**: Handle protocol fees and rewards

## Contract Functions

### Staking
- `stake`: Stake STX tokens
- `unstake`: Withdraw staked tokens
- `distribute-staking-rewards`: Distribute rewards to stakers

### DAO
- `create-proposal`: Create new governance proposals
- `vote-proposal`: Vote on active proposals
- `execute-proposal`: Execute approved proposals

### Lending
- `request-loan`: Request a loan with NFT collateral
- `fund-loan`: Fund an existing loan request
- `repay-loan`: Repay an active loan

### Insurance
- `create-insurance-pool`: Create new insurance pools
- `buy-policy`: Purchase insurance coverage
- `submit-claim`: Submit insurance claims
- `vote-claim`: Vote on claim validity
- `payout-claim`: Process approved claims

### Prediction Markets
- `create-market`: Create new prediction markets
- `place-bet`: Place bets on markets
- `resolve-market`: Resolve market outcomes
- `claim-winnings`: Claim winnings from correct predictions

## Error Codes

- `ERR_NOT_FOUND (u100)`: Resource not found
- `ERR_UNAUTHORIZED (u101)`: Unauthorized operation
- `ERR_INSUFFICIENT_FUNDS (u102)`: Insufficient funds
- `ERR_ALREADY_EXECUTED (u103)`: Action already executed
- `ERR_INVALID (u104)`: Invalid operation

## License

MIT License
