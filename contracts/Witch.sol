// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.6;

import "@yield-protocol/utils-v2/contracts/access/AccessControl.sol";
import "@yield-protocol/vault-interfaces/ILadle.sol";
import "@yield-protocol/vault-interfaces/ICauldron.sol";
import "@yield-protocol/vault-interfaces/IJoin.sol";
import "@yield-protocol/vault-interfaces/DataTypes.sol";
import "@yield-protocol/utils-v2/contracts/math/WMul.sol";
import "@yield-protocol/utils-v2/contracts/math/WMulUp.sol";
import "@yield-protocol/utils-v2/contracts/math/WDiv.sol";
import "@yield-protocol/utils-v2/contracts/math/WDivUp.sol";
import "@yield-protocol/utils-v2/contracts/cast/CastU256U128.sol";
import "@yield-protocol/utils-v2/contracts/cast/CastU256U32.sol";


/// @title  The Witch is a Liquidation Engine for the Yield protocol
/// @notice The Witch grabs uncollateralized vaults, replacing the owner by itself. Then it sells the vault collateral
/// in exchange for underlying to pay its debt. The amount of collateral given increases over time, until it offers
/// to sell all the collateral for underlying to pay all the debt. The auction is held open at the final price indefinitely.
/// @dev After the debt is settled, the Witch returns the vault to its original owner.
contract Witch is AccessControl {
    using WMul for uint256;
    using WMulUp for uint256;
    using WDiv for uint256;
    using WDivUp for uint256;
    using CastU256U128 for uint256;
    using CastU256U32 for uint256;

    event Point(bytes32 indexed param, address indexed value);
    event IlkSet(bytes6 indexed ilkId, uint32 duration, uint64 initialOffer, uint96 line, uint24 dust, uint8 dec);
    event Bought(bytes12 indexed vaultId, address indexed buyer, uint256 ink, uint256 art);
    event Auctioned(bytes12 indexed vaultId, uint256 indexed start);

    struct Auction {
        address owner;
        uint32 start;
    }

    struct Ilk {
        uint32 duration;     // Time that auctions take to go to minimal price and stay there
        uint64 initialOffer; // Proportion of collateral that is sold at auction start (1e18 = 100%)
    }

    struct Limits {
        uint96 line;         // Maximum concurrent auctioned collateral
        uint24 dust;         // Minimum collateral that must be left when buying, unless buying all
        uint8 dec;           // Multiplying factor (10**dec) for line and dust
        uint128 sum;         // Current concurrent auctioned collateral
    }

    ICauldron public immutable cauldron;
    ILadle public ladle;
    mapping(bytes12 => Auction) public auctions;
    mapping(bytes6 => Ilk) public ilks;
    mapping(bytes6 => Limits) public limits;

    constructor(ICauldron cauldron_, ILadle ladle_) {
        cauldron = cauldron_;
        ladle = ladle_;
    }

    /// @dev Point to a different ladle
    function point(bytes32 param, address value) external auth {
        require(param == "ladle", "Unrecognized");
        ladle = ILadle(value);
        emit Point(param, value);
    }

    /// @dev Governance function to set:
    ///  - the auction duration to calculate liquidation prices
    ///  - the proportion of the collateral that will be sold at auction start
    ///  - the maximum collateral that can be auctioned at the same time
    ///  - the minimum collateral that must be left when buying, unless buying all
    ///  - The decimals for maximum and minimum
    /// @param ilkId Id of asset used for collateral
    /// @param duration Time that auctions take to go to minimal price
    /// @param initialOffer Proportion of collateral that is sold at auction start (1e18 = 100%)
    /// @param line Maximum concurrent auctioned collateral
    /// @param dust Minimum collateral that must be left when buying, unless buying all
    /// @param dec Multiplying factor (10**dec) for line and dust
    function setIlk(
        bytes6 ilkId,
        uint32 duration,
        uint64 initialOffer,
        uint96 line,
        uint24 dust,
        uint8 dec
    ) external auth {
        require(initialOffer <= 1e18, "Only at or under 100%");
        ilks[ilkId] = Ilk({duration: duration, initialOffer: initialOffer});
        limits[ilkId] = Limits({
            line: line,
            dust: dust,
            dec: dec,
            sum: limits[ilkId].sum // sum is initialized at zero, and doesn't change when changing any ilk parameters
        });
        emit IlkSet(ilkId, duration, initialOffer, line, dust, dec);
    }

    /// @dev Put an undercollateralized vault up for liquidation
    /// @param vaultId Id of vault to liquidate
    function auction(bytes12 vaultId) external {
        require(auctions[vaultId].start == 0, "Vault already under auction");
        require(cauldron.level(vaultId) < 0, "Not undercollateralized");

        DataTypes.Vault memory vault_ = cauldron.vaults(vaultId);
        DataTypes.Balances memory balances_ = cauldron.balances(vaultId);
        Limits memory limits_ = limits[vault_.ilkId];
        limits_.sum += balances_.ink;
        require(limits_.sum <= limits_.line * (10**limits_.dec), "Collateral limit reached");

        limits[vault_.ilkId] = limits_;
        auctions[vaultId] = Auction({owner: vault_.owner, start: block.timestamp.u32()});
        cauldron.give(vaultId, address(this));
        emit Auctioned(vaultId, block.timestamp.u32());
    }

    /// @dev Pay `base` of the debt in a vault in liquidation, getting at least `min` collateral.
    /// Use `payAll` to pay all the debt, using `buy` for amounts close to the whole vault might revert.
    /// @param vaultId Id of vault to buy
    /// @param base Amount of base to pay
    /// @param min Minimum amount of collateral that must be received
    /// @return ink Amount of vault collateral received
    function buy(
        bytes12 vaultId,
        uint128 base,
        uint128 min
    ) external returns (uint256 ink) {
        require(auctions[vaultId].start > 0, "Vault not under auction");
        DataTypes.Vault memory vault_ = cauldron.vaults(vaultId);
        DataTypes.Series memory series_ = cauldron.series(vault_.seriesId);
        DataTypes.Balances memory balances_ = cauldron.balances(vaultId);
        require(balances_.art > 0, "Nothing to buy"); // Cheapest way of failing gracefully if given a non existing vault

        Auction memory auction_ = auctions[vaultId];
        Ilk memory ilk_ = ilks[vault_.ilkId];
        Limits memory limits_ = limits[vault_.ilkId];

        uint256 art = cauldron.debtFromBase(vault_.seriesId, base);
        {

            // If the world is still here, auctions will malfunction on the 7th of February 2106, at 06:28:16 GMT
            // TODO: Replace this contract before then 😰
            uint256 elapsed = uint32(block.timestamp) - auction_.start;

            //       (        a         )
            // ink = (art_in / total_art) * total_ink * (p + (1 - p) * t)

            uint256 t = elapsed > ilk_.duration ? 1 : elapsed.wdiv(ilk_.duration);

            uint256 a = art.wdiv(balances_.art);
            uint256 p = ilk_.initialOffer;
            ink = a.wmul(balances_.ink).wmul(p + (10 ** 18 - p).wmul(t));

            require(ink >= min, "Not enough bought");
            require(art == balances_.art || balances_.ink - ink >= limits_.dust * (10**limits_.dec), "Leaves dust");
            limits[vault_.ilkId].sum = limits_.sum - ink.u128();
        }

        cauldron.slurp(vaultId, ink.u128(), art.u128()); // Remove debt and collateral from the vault
        _settle(msg.sender, vault_.ilkId, series_.baseId, ink.u128(), base); // Move the assets
        if (balances_.art - art == 0) {
            // If there is no debt left, return the vault with the collateral to the owner
            cauldron.give(vaultId, auction_.owner);
            delete auctions[vaultId];
        }

        emit Bought(vaultId, msg.sender, ink, art);
    }

    // /// @dev Pay all debt from a vault in liquidation, getting at least `min` collateral.
    // /// @param vaultId Id of vault to buy
    // /// @param min Minimum amount of collateral that must be received
    // /// @return ink Amount of vault collateral received
    // function payAll(bytes12 vaultId, uint128 min) external returns (uint256 ink) {
    //     require(auctions[vaultId].start > 0, "Vault not under auction");
    //     DataTypes.Vault memory vault_ = cauldron.vaults(vaultId);
    //     DataTypes.Series memory series_ = cauldron.series(vault_.seriesId);
    //     DataTypes.Balances memory balances_ = cauldron.balances(vaultId);
    //     Auction memory auction_ = auctions[vaultId];
    //     Ilk memory ilk_ = ilks[vault_.ilkId];

    //     require(balances_.art > 0, "Nothing to buy"); // Cheapest way of failing gracefully if given a non existing vault
    //     {
    //         uint256 elapsed = uint32(block.timestamp) - auction_.start; // Auctions will malfunction on the 7th of February 2106, at 06:28:16 GMT, we should replace this contract before then.
    //         uint256 price = _inkPrice(balances_, ilk_.initialOffer, ilk_.duration, elapsed);
    //         ink = uint256(balances_.art).wmul(price); // Calculate collateral to sell. Using divdrup stops rounding from leaving 1 stray wei in vaults.
    //         require(ink >= min, "Not enough bought");
    //         ink = (ink > balances_.ink) ? balances_.ink : ink; // The price is rounded up, so we cap this at all the collateral and no more
    //         limits[vault_.ilkId].sum -= ink.u128();
    //     }

    //     cauldron.slurp(vaultId, ink.u128(), balances_.art); // Remove debt and collateral from the vault
    //     _settle(
    //         msg.sender,
    //         vault_.ilkId,
    //         series_.baseId,
    //         ink.u128(),
    //         cauldron.debtToBase(vault_.seriesId, balances_.art)
    //     ); // Move the assets
    //     cauldron.give(vaultId, auction_.owner);
    //     delete auctions[vaultId];

    //     emit Bought(vaultId, msg.sender, ink, balances_.art); // Still the initially read `art` value, not the updated one
    // }

    /// @dev Move base from the buyer to the protocol, and collateral from the protocol to the buyer
    /// @param user  Address of buyer
    /// @param ilkId Id of asset used for collateral
    /// @param baseId Id of borrowed token
    /// @param ink Amount of collateral
    /// @param art Amount of debt
    function _settle(
        address user,
        bytes6 ilkId,
        bytes6 baseId,
        uint128 ink,
        uint128 art
    ) private {
        if (ink != 0) {
            // Give collateral to the user
            IJoin ilkJoin = ladle.joins(ilkId);
            require(ilkJoin != IJoin(address(0)), "Join not found");
            ilkJoin.exit(user, ink);
        }
        if (art != 0) {
            // Take underlying from user
            IJoin baseJoin = ladle.joins(baseId);
            require(baseJoin != IJoin(address(0)), "Join not found");
            baseJoin.join(user, art);
        }
    }

//     /// @dev Price of a collateral unit, in underlying, at the present moment, for a given vault. Rounds up, sometimes twice.
//     ///            ink                     min(auction, elapsed)
//     /// price = (------- * (p + (1 - p) * -----------------------))
//     ///            art                          auction
//     /// @param initialOffer Proportion of collateral that is sold at auction start (1e18 = 100%)
//     /// @param duration Time that auctions take to go to minimal price
//     /// @param elapsed Time that has passed since auction began
//     /// @return price Current price of collateral
//     function _inkPrice(
//         DataTypes.Balances memory balances,
//         uint256 initialOffer,
//         uint256 duration,
//         uint256 elapsed
//     ) private pure returns (uint256 price) {
//         uint256 term1 = uint256(balances.ink).wdivup(balances.art);
//         uint256 dividend2 = duration < elapsed ? duration : elapsed;
//         uint256 divisor2 = duration;
//         uint256 term2 = initialOffer + (1e18 - initialOffer).wmulup(dividend2.wdivup(divisor2));
//         price = term1.wmulup(term2);
//     }
}
