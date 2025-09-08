// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// No external imports needed - using custom math functions

/**
 * @title GNUSDAOVotingMechanismsFacet
 * @dev Diamond facet for advanced voting calculations and mechanisms
 * Adapted from Decentralized_Voting_DAO VotingMechanisms library
 * Features:
 * - Quadratic voting cost calculations
 * - Vote weight calculations
 * - Result tallying and analysis
 * - Sybil resistance metrics
 */
contract GNUSDAOVotingMechanismsFacet {

    // Custom Errors
    error ZeroVotes();
    error VotesTooLarge();
    
    struct VoteAnalysis {
        uint256 totalVotes;
        uint256 totalVoters;
        uint256 totalTokensSpent;
        uint256 averageVotesPerVoter;
        uint256 medianVotesPerVoter;
        uint256 giniCoefficient; // Measure of vote distribution inequality
    }
    
    struct QuadraticVoteData {
        uint256 votes;
        uint256 cost;
        address voter;
    }
    
    /**
     * @dev Calculate quadratic voting cost
     * @param votes Number of votes to cast
     * @return cost Token cost for the votes (votes²)
     */
    function calculateQuadraticCost(uint256 votes) external pure returns (uint256 cost) {
        if (votes == 0) {
            revert ZeroVotes();
        }

        // Prevent overflow for very large vote counts
        if (votes > type(uint128).max) {
            revert VotesTooLarge();
        }
        
        cost = votes * votes;
    }
    
    /**
     * @dev Calculate maximum votes possible with given token balance
     * @param tokenBalance Available token balance
     * @return maxVotes Maximum votes that can be cast
     */
    function calculateMaxVotes(uint256 tokenBalance) external pure returns (uint256 maxVotes) {
        if (tokenBalance == 0) return 0;
        
        // Find the largest integer n such that n² <= tokenBalance
        maxVotes = _sqrt(tokenBalance);
    }
    
    /**
     * @dev Calculate vote weight based on quadratic voting
     * @param tokensCost Tokens spent on voting
     * @return weight Vote weight (square root of tokens spent)
     */
    function calculateVoteWeight(uint256 tokensCost) external pure returns (uint256 weight) {
        if (tokensCost == 0) return 0;
        weight = _sqrt(tokensCost);
    }
    
    /**
     * @dev Calculate Sybil resistance score
     * @param totalVoters Number of unique voters
     * @param totalTokensSpent Total tokens spent on voting
     * @param maxTokensPerVoter Maximum tokens spent by any single voter
     * @return score Sybil resistance score (0-100, higher is better)
     */
    function calculateSybilResistanceScore(
        uint256 totalVoters,
        uint256 totalTokensSpent,
        uint256 maxTokensPerVoter
    ) external pure returns (uint256 score) {
        if (totalVoters == 0 || totalTokensSpent == 0) return 0;
        
        // Calculate average tokens per voter
        uint256 avgTokensPerVoter = totalTokensSpent / totalVoters;
        
        // Calculate concentration ratio (max / average)
        uint256 concentrationRatio = (maxTokensPerVoter * 100) / avgTokensPerVoter;
        
        // Score decreases as concentration increases
        if (concentrationRatio <= 100) {
            score = 100; // Perfect distribution
        } else if (concentrationRatio <= 200) {
            score = 200 - concentrationRatio; // Linear decrease
        } else {
            score = 0; // High concentration
        }
    }
    
    /**
     * @dev Calculate participation rate
     * @param voters Number of voters
     * @param eligibleVoters Total number of eligible voters
     * @return rate Participation rate as percentage (0-100)
     */
    function calculateParticipationRate(
        uint256 voters,
        uint256 eligibleVoters
    ) external pure returns (uint256 rate) {
        if (eligibleVoters == 0) return 0;
        rate = (voters * 100) / eligibleVoters;
    }
    
    /**
     * @dev Check if proposal meets quorum requirements
     * @param totalVotes Total votes cast
     * @param quorumThreshold Minimum votes required for quorum
     * @return meetsQuorum True if quorum is met
     */
    function checkQuorum(
        uint256 totalVotes,
        uint256 quorumThreshold
    ) external pure returns (bool meetsQuorum) {
        meetsQuorum = totalVotes >= quorumThreshold;
    }
    
    /**
     * @dev Calculate vote distribution metrics
     * @param voteData Array of vote data
     * @return analysis Detailed analysis of vote distribution
     */
    function analyzeVoteDistribution(
        QuadraticVoteData[] memory voteData
    ) external pure returns (VoteAnalysis memory analysis) {
        uint256 length = voteData.length;
        if (length == 0) {
            return analysis; // Return empty analysis
        }
        
        // Calculate totals
        uint256 totalVotes = 0;
        uint256 totalTokensSpent = 0;
        
        for (uint256 i = 0; i < length; i++) {
            totalVotes += voteData[i].votes;
            totalTokensSpent += voteData[i].cost;
        }
        
        analysis.totalVotes = totalVotes;
        analysis.totalVoters = length;
        analysis.totalTokensSpent = totalTokensSpent;
        analysis.averageVotesPerVoter = length > 0 ? totalVotes / length : 0;
        
        // Calculate median (simplified for gas efficiency)
        if (length > 0) {
            // Sort votes array (bubble sort for simplicity)
            uint256[] memory sortedVotes = new uint256[](length);
            for (uint256 i = 0; i < length; i++) {
                sortedVotes[i] = voteData[i].votes;
            }
            
            // Simple bubble sort
            for (uint256 i = 0; i < length - 1; i++) {
                for (uint256 j = 0; j < length - i - 1; j++) {
                    if (sortedVotes[j] > sortedVotes[j + 1]) {
                        uint256 temp = sortedVotes[j];
                        sortedVotes[j] = sortedVotes[j + 1];
                        sortedVotes[j + 1] = temp;
                    }
                }
            }
            
            // Calculate median
            if (length % 2 == 0) {
                analysis.medianVotesPerVoter = (sortedVotes[length / 2 - 1] + sortedVotes[length / 2]) / 2;
            } else {
                analysis.medianVotesPerVoter = sortedVotes[length / 2];
            }
        }
        
        // Calculate simplified Gini coefficient
        analysis.giniCoefficient = _calculateGiniCoefficient(voteData);
    }
    
    /**
     * @dev Calculate simplified Gini coefficient for vote distribution
     * @param voteData Array of vote data
     * @return gini Gini coefficient (0-100, 0 = perfect equality, 100 = perfect inequality)
     */
    function _calculateGiniCoefficient(
        QuadraticVoteData[] memory voteData
    ) internal pure returns (uint256 gini) {
        uint256 length = voteData.length;
        if (length <= 1) return 0;
        
        uint256 totalVotes = 0;
        for (uint256 i = 0; i < length; i++) {
            totalVotes += voteData[i].votes;
        }
        
        if (totalVotes == 0) return 0;
        
        uint256 sum = 0;
        for (uint256 i = 0; i < length; i++) {
            for (uint256 j = 0; j < length; j++) {
                if (voteData[i].votes > voteData[j].votes) {
                    sum += voteData[i].votes - voteData[j].votes;
                }
            }
        }
        
        // Simplified Gini calculation
        gini = (sum * 100) / (length * totalVotes);
    }
    
    /**
     * @dev Validate vote parameters
     * @param votes Number of votes
     * @param maxVotesPerWallet Maximum allowed votes per wallet
     * @param tokenBalance Available token balance
     * @return valid True if vote parameters are valid
     * @return cost Token cost for the votes
     */
    function validateVote(
        uint256 votes,
        uint256 maxVotesPerWallet,
        uint256 tokenBalance
    ) external pure returns (bool valid, uint256 cost) {
        if (votes == 0) return (false, 0);
        if (votes > maxVotesPerWallet) return (false, 0);
        
        cost = votes * votes; // Quadratic cost calculation
        valid = cost <= tokenBalance;
    }
    
    /**
     * @dev Calculate optimal vote allocation for given token budget
     * @param tokenBudget Available tokens to spend
     * @param maxVotesPerWallet Maximum allowed votes per wallet
     * @return optimalVotes Optimal number of votes to cast
     * @return remainingTokens Tokens remaining after optimal allocation
     */
    function calculateOptimalVotes(
        uint256 tokenBudget,
        uint256 maxVotesPerWallet
    ) external pure returns (uint256 optimalVotes, uint256 remainingTokens) {
        if (tokenBudget == 0) return (0, 0);
        
        optimalVotes = _sqrt(tokenBudget);
        
        // Ensure we don't exceed the per-wallet limit
        if (optimalVotes > maxVotesPerWallet) {
            optimalVotes = maxVotesPerWallet;
        }
        
        uint256 cost = optimalVotes * optimalVotes; // Quadratic cost
        remainingTokens = tokenBudget - cost;
    }
    
    /**
     * @dev Get vote efficiency (votes per token spent)
     * @param votes Number of votes cast
     * @param tokensCost Tokens spent
     * @return efficiency Efficiency ratio (scaled by 1000 for precision)
     */
    function getVoteEfficiency(uint256 votes, uint256 tokensCost) external pure returns (uint256 efficiency) {
        if (tokensCost == 0) return 0;
        efficiency = (votes * 1000) / tokensCost;
    }

    /**
     * @dev Internal function to calculate square root using Babylonian method
     * @param x Number to calculate square root for
     * @return y Square root of x
     */
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;

        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
