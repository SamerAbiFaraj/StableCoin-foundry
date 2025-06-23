//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

/**
 * @title Oracle Library
 * @author Samer Abi Faraj
 * @notice This library is used to chek the chainlink oracle for state data.
 * If a price is stale, the function will revert, and rander the DSCEngine unusable -- this is by design
 * We want the DSCEngine to freeze if prices become stale
 *
 * So if the chainlink netwrk explodes and you have a lot of money locked in the protocol... you are in troble !!
 *
 */
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

library OracleLib {
    error OracleLib__StalePrice();
    error OracleLib__PriceNotPositive();
    error OracleLib__IncompleteRound();

    uint256 private constant TIMEOUT = 3 hours; // 3*60*60 = 10800 seconds

    /**
     * @notice Retrieves the latest round data from a Chainlink price feed and checks for staleness, positive price, and round completion.
     * @param priceFeed The AggregatorV3Interface instance of the Chainlink price feed.
     * @return roundId The ID of the round.
     * @return answer The price.
     * @return startedAt Timestamp of when the round started.
     * @return updatedAt Timestamp of when the round was last updated.
     * @return answeredInRound The round ID in which the answer was computed.
     * @dev Reverts with OracleLib__StalePrice if the price data is older than TIMEOUT.
     * @dev Reverts with OracleLib__PriceNotPositive if the price is not greater than zero.
     * @dev Reverts with OracleLib__IncompleteRound if answeredInRound is less than roundId.
     */
    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (roundId, answer, startedAt, updatedAt, answeredInRound) = priceFeed.latestRoundData();

        uint256 secondsSince = block.timestamp - updatedAt;
        if (secondsSince > TIMEOUT) {
            revert OracleLib__StalePrice();
        }

        if (answer <= 0) {
            revert OracleLib__PriceNotPositive();
        }

        if (answeredInRound < roundId) {
            revert OracleLib__IncompleteRound();
        }
        // No need to explicitly return the tuple, named return values are used.
    }
}
