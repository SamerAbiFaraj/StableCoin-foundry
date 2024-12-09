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

    uint256 private constant TIMEOUT = 3 hours; // 3*60*60 = 10800 seconds  (This is the time the new pricefeed should
        // be update by the aggregator in reality this is usually 1 hour (3600seconds))

    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        uint256 secondsSince = block.timestamp - updatedAt;
        if (secondsSince > TIMEOUT) {
            revert OracleLib__StalePrice();
        }
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
