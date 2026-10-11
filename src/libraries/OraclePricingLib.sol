// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IBucketInfo} from "../interfaces/IBucketInfo.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @notice Tracks outpriced and manually priced held tokens.
library OraclePricingLib {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev Last recorded aggregate outpriced status.
    struct OutpricedTracker {
        bool lastKnownOutpriced;
    }

    /// @notice Emitted when the aggregate outpriced status changes.
    event OutpricedStatusChanged(bool wasOutpriced, bool isOutpriced);

    /// @notice Whether any held token may be outpriced.
    function isAnyOutpriced(IBucketInfo bucketInfo, EnumerableSet.AddressSet storage heldTokens)
        public
        view
        returns (bool)
    {
        uint256 n = heldTokens.length();
        for (uint256 i = 0; i < n; i++) {
            if (bucketInfo.isPotentiallyOutpriced(heldTokens.at(i))) {
                return true;
            }
        }
        return false;
    }

    /// @notice Return held tokens whose feeds may be outpriced.
    function getOutpricedHeldTokens(IBucketInfo bucketInfo, EnumerableSet.AddressSet storage heldTokens)
        public
        view
        returns (address[] memory outpriced)
    {
        uint256 n = heldTokens.length();
        address[] memory buf = new address[](n);
        uint256 count = 0;
        for (uint256 i = 0; i < n; i++) {
            address token = heldTokens.at(i);
            if (bucketInfo.isPotentiallyOutpriced(token)) {
                buf[count++] = token;
            }
        }
        outpriced = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            outpriced[i] = buf[i];
        }
    }

    /// @notice Return held tokens without a Chainlink feed.
    function getManualPricedHeldTokens(IBucketInfo bucketInfo, EnumerableSet.AddressSet storage heldTokens)
        public
        view
        returns (address[] memory manuallyPriced)
    {
        uint256 n = heldTokens.length();
        address[] memory buf = new address[](n);
        uint256 count = 0;
        for (uint256 i = 0; i < n; i++) {
            address token = heldTokens.at(i);
            if (bucketInfo.getPriceFeed(token) == address(0)) {
                buf[count++] = token;
            }
        }
        manuallyPriced = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            manuallyPriced[i] = buf[i];
        }
    }

    /// @notice Update the aggregate outpriced status and emit on change.
    function syncOutpricedStatus(
        OutpricedTracker storage tracker,
        IBucketInfo bucketInfo,
        EnumerableSet.AddressSet storage heldTokens
    ) public returns (bool isOutpriced) {
        bool wasOutpriced = tracker.lastKnownOutpriced;
        isOutpriced = isAnyOutpriced(bucketInfo, heldTokens);
        if (isOutpriced != wasOutpriced) {
            tracker.lastKnownOutpriced = isOutpriced;
            emit OutpricedStatusChanged(wasOutpriced, isOutpriced);
        }
    }
}
