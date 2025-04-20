// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import './Interfaces/IBorrowerOperations.sol';
import './Interfaces/IStabilityPool.sol';
import './Interfaces/IBorrowerOperations.sol';
import './Interfaces/ITroveManager.sol';
import './Interfaces/ILUSDToken.sol';
import './Interfaces/ISortedTroves.sol';
import "./Interfaces/ICommunityIssuance.sol";
import "./Dependencies/LiquityBase.sol";
import "./Dependencies/SafeMath.sol";
import "./Dependencies/Ownable.sol";
import "./Dependencies/CheckContract.sol";
//import "./Dependencies/console.sol";

/*
 * The Stability Pool holds LUSD tokens deposited by Stability Pool depositors.
 * ... (rest of the comments remain the same) ...
 */
contract StabilityPool is LiquityBase, Ownable, CheckContract, IStabilityPool {
    // using SafeMath for uint256; // Removed as SafeMath is replaced

    string constant public NAME = "StabilityPool";

    IBorrowerOperations public borrowerOperations;

    ITroveManager public troveManager;

    ILUSDToken public lusdToken;

    // Needed to check if there are pending liquidations
    ISortedTroves public sortedTroves;

    ICommunityIssuance public communityIssuance;

    uint256 internal ETH;  // deposited ether tracker

    // Tracker for LUSD held in the pool. Changes when users deposit/withdraw, and when Trove debt is offset.
    uint256 internal totalLUSDDeposits;

   // --- Data structures ---

    struct FrontEnd {
        uint kickbackRate;
        bool registered;
    }

    struct Deposit {
        uint initialValue;
        address frontEndTag;
    }

    struct Snapshots {
        uint S;
        uint P;
        uint G;
        uint scale;
    }

    mapping (address => Deposit) public deposits;  // depositor address -> Deposit struct
    mapping (address => Snapshots) public depositSnapshots;  // depositor address -> snapshots struct

    mapping (address => FrontEnd) public frontEnds;  // front end address -> FrontEnd struct
    mapping (address => uint) public frontEndStakes; // front end address -> last recorded total deposits, tagged with that front end
    mapping (address => Snapshots) public frontEndSnapshots; // front end address -> snapshots struct

    // We never allow the SP to go below this amount through withdrawals or liquidations
    uint constant internal MIN_LUSD_IN_SP = 1e18;

    /*  Product 'P': Running product by which to multiply an initial deposit, in order to find the current compounded deposit,
    * after a series of liquidations have occurred, each of which cancel some LUSD debt with the deposit.
    *
    * During its lifetime, a deposit's value evolves from d_t to d_t * P / P_t , where P_t
    * is the snapshot of P taken at the instant the deposit was made. 18-digit decimal.
    */
    uint public P = DECIMAL_PRECISION;

    uint public constant SCALE_FACTOR = 1e9;

    // Each time the scale of P shifts by SCALE_FACTOR, the scale is incremented by 1
    uint public currentScale;

    /* ETH Gain sum 'S': During its lifetime, each deposit d_t earns an ETH gain of ( d_t * [S - S_t] )/P_t, where S_t
    * is the depositor's snapshot of S taken at the time t when the deposit was made.
    *
    * The 'S' sums are stored in a mapping (scale => sum), that records the sum S at different scales
    */
    mapping(uint => uint) public scaleToSum;

    /*
    * Similarly, the sum 'G' is used to calculate LQTY gains. During it's lifetime, each deposit d_t earns a LQTY gain of
    *  ( d_t * [G - G_t] )/P_t, where G_t is the depositor's snapshot of G taken at time t when  the deposit was made.
    *
    *  LQTY reward events occur are triggered by depositor operations (new deposit, topup, withdrawal), and liquidations.
    *  In each case, the LQTY reward is issued (i.e. G is updated), before other state changes are made.
    */
    mapping(uint => uint) public scaleToG;

    // Error tracker for the error correction in the LQTY issuance calculation
    uint public lastLQTYError;
    // Error trackers for the error correction in the offset calculation
    uint public lastETHError_Offset;
    uint public lastLUSDLossError_Offset;

    // --- Events ---
    // All events are inherited from IStabilityPool

    // --- Contract setters ---

    function setAddresses(
        address _borrowerOperationsAddress,
        address _troveManagerAddress,
        address _activePoolAddress,
        address _lusdTokenAddress,
        address _sortedTrovesAddress,
        address _priceFeedAddress,
        address _communityIssuanceAddress
    )
        external
        override
        onlyOwner
    {
        checkContract(_borrowerOperationsAddress);
        checkContract(_troveManagerAddress);
        checkContract(_activePoolAddress);
        checkContract(_lusdTokenAddress);
        checkContract(_sortedTrovesAddress);
        checkContract(_priceFeedAddress);
        checkContract(_communityIssuanceAddress);

        borrowerOperations = IBorrowerOperations(_borrowerOperationsAddress);
        troveManager = ITroveManager(_troveManagerAddress);
        activePool = IActivePool(_activePoolAddress);
        lusdToken = ILUSDToken(_lusdTokenAddress);
        sortedTroves = ISortedTroves(_sortedTrovesAddress);
        priceFeed = IPriceFeed(_priceFeedAddress);
        communityIssuance = ICommunityIssuance(_communityIssuanceAddress);

        emit BorrowerOperationsAddressChanged(_borrowerOperationsAddress);
        emit TroveManagerAddressChanged(_troveManagerAddress);
        emit ActivePoolAddressChanged(_activePoolAddress);
        emit LUSDTokenAddressChanged(_lusdTokenAddress);
        emit SortedTrovesAddressChanged(_sortedTrovesAddress);
        emit PriceFeedAddressChanged(_priceFeedAddress);
        emit CommunityIssuanceAddressChanged(_communityIssuanceAddress);

        _renounceOwnership();
    }

    // --- Getters for public variables. Required by IPool interface ---

    function getETH() external view override returns (uint) {
        return ETH;
    }

    function getTotalLUSDDeposits() external view override returns (uint) {
        return totalLUSDDeposits;
    }

    // --- External Depositor Functions ---

    /*  provideToSP():
    *
    * - Triggers a LQTY issuance, based on time passed since the last issuance. The LQTY issuance is shared between *all* depositors and front ends
    * - Tags the deposit with the provided front end tag param, if it's a new deposit
    * - Sends depositor's accumulated gains (LQTY, ETH) to depositor
    * - Sends the tagged front end's accumulated LQTY gains to the tagged front end
    * - Increases deposit and tagged front end's stake, and takes new snapshots for each.
    */
    function provideToSP(uint _amount, address _frontEndTag) external override {
        _requireFrontEndIsRegisteredOrZero(_frontEndTag);
        _requireFrontEndNotRegistered(msg.sender);
        _requireNonZeroAmount(_amount);

        uint initialDeposit = deposits[msg.sender].initialValue;

        ICommunityIssuance communityIssuanceCached = communityIssuance;

        _triggerLQTYIssuance(communityIssuanceCached);

        if (initialDeposit == 0) {_setFrontEndTag(msg.sender, _frontEndTag);}
        uint depositorETHGain = getDepositorETHGain(msg.sender);
        uint compoundedLUSDDeposit = getCompoundedLUSDDeposit(msg.sender);
        uint LUSDLoss = initialDeposit - compoundedLUSDDeposit; // Using '-' // Needed only for event log

        // First pay out any LQTY gains
        address frontEnd = deposits[msg.sender].frontEndTag;
        _payOutLQTYGains(communityIssuanceCached, msg.sender, frontEnd);

        // Update front end stake
        uint compoundedFrontEndStake = getCompoundedFrontEndStake(frontEnd);
        uint newFrontEndStake = compoundedFrontEndStake + _amount; // Using '+'
        _updateFrontEndStakeAndSnapshots(frontEnd, newFrontEndStake);
        emit FrontEndStakeChanged(frontEnd, newFrontEndStake, msg.sender);

        _sendLUSDtoStabilityPool(msg.sender, _amount);

        uint newDeposit = compoundedLUSDDeposit + _amount; // Using '+'
        _updateDepositAndSnapshots(msg.sender, newDeposit);
        emit UserDepositChanged(msg.sender, newDeposit);

        emit ETHGainWithdrawn(msg.sender, depositorETHGain, LUSDLoss); // LUSD Loss required for event log

        _sendETHGainToDepositor(depositorETHGain);
     }

    /*  withdrawFromSP():
    *
    * - Triggers a LQTY issuance, based on time passed since the last issuance. The LQTY issuance is shared between *all* depositors and front ends
    * - Removes the deposit's front end tag if it is a full withdrawal
    * - Sends all depositor's accumulated gains (LQTY, ETH) to depositor
    * - Sends the tagged front end's accumulated LQTY gains to the tagged front end
    * - Decreases deposit and tagged front end's stake, and takes new snapshots for each.
    *
    * If _amount > userDeposit, the user withdraws all of their compounded deposit.
    */
    function withdrawFromSP(uint _amount) external override {
        if (_amount !=0) {_requireNoUnderCollateralizedTroves();}
        uint initialDeposit = deposits[msg.sender].initialValue;
        _requireUserHasDeposit(initialDeposit);

        ICommunityIssuance communityIssuanceCached = communityIssuance;

        _triggerLQTYIssuance(communityIssuanceCached);

        uint depositorETHGain = getDepositorETHGain(msg.sender);

        uint compoundedLUSDDeposit = getCompoundedLUSDDeposit(msg.sender);
        uint LUSDtoWithdraw = LiquityMath._min(_amount, compoundedLUSDDeposit);
        uint LUSDLoss = initialDeposit - compoundedLUSDDeposit; // Using '-' // Needed only for event log

        // First pay out any LQTY gains
        address frontEnd = deposits[msg.sender].frontEndTag;
        _payOutLQTYGains(communityIssuanceCached, msg.sender, frontEnd);
        
        // Update front end stake
        uint compoundedFrontEndStake = getCompoundedFrontEndStake(frontEnd);
        uint newFrontEndStake = compoundedFrontEndStake - LUSDtoWithdraw; // Using '-'
        _updateFrontEndStakeAndSnapshots(frontEnd, newFrontEndStake);
        emit FrontEndStakeChanged(frontEnd, newFrontEndStake, msg.sender);

        // It will check that total does not go below MIN_LUSD_IN_SP
        _sendLUSDToDepositor(msg.sender, LUSDtoWithdraw);

        // Update deposit
        uint newDeposit = compoundedLUSDDeposit - LUSDtoWithdraw; // Using '-'
        _updateDepositAndSnapshots(msg.sender, newDeposit);
        emit UserDepositChanged(msg.sender, newDeposit);

        emit ETHGainWithdrawn(msg.sender, depositorETHGain, LUSDLoss);  // LUSD Loss required for event log

        _sendETHGainToDepositor(depositorETHGain);
    }

    /* withdrawETHGainToTrove:
    * - Triggers a LQTY issuance, based on time passed since the last issuance. The LQTY issuance is shared between *all* depositors and front ends
    * - Sends all depositor's LQTY gain to  depositor
    * - Sends all tagged front end's LQTY gain to the tagged front end
    * - Transfers the depositor's entire ETH gain from the Stability Pool to the caller's trove
    * - Leaves their compounded deposit in the Stability Pool
    * - Updates snapshots for deposit and tagged front end stake */
    function withdrawETHGainToTrove(address _upperHint, address _lowerHint) external override {
        uint initialDeposit = deposits[msg.sender].initialValue;
        _requireUserHasDeposit(initialDeposit);
        _requireUserHasTrove(msg.sender);
        _requireUserHasETHGain(msg.sender);

        ICommunityIssuance communityIssuanceCached = communityIssuance;

        _triggerLQTYIssuance(communityIssuanceCached);

        uint depositorETHGain = getDepositorETHGain(msg.sender);

        uint compoundedLUSDDeposit = getCompoundedLUSDDeposit(msg.sender);
        uint LUSDLoss = initialDeposit - compoundedLUSDDeposit; // Using '-' // Needed only for event log

        // First pay out any LQTY gains
        address frontEnd = deposits[msg.sender].frontEndTag;
        _payOutLQTYGains(communityIssuanceCached, msg.sender, frontEnd);

        // Update front end stake
        uint compoundedFrontEndStake = getCompoundedFrontEndStake(frontEnd);
        uint newFrontEndStake = compoundedFrontEndStake;
        _updateFrontEndStakeAndSnapshots(frontEnd, newFrontEndStake);
        emit FrontEndStakeChanged(frontEnd, newFrontEndStake, msg.sender);

        _updateDepositAndSnapshots(msg.sender, compoundedLUSDDeposit);

        /* Emit events before transferring ETH gain to Trove.
         This lets the event log make more sense (i.e. so it appears that first the ETH gain is withdrawn
        and then it is deposited into the Trove, not the other way around). */
        emit ETHGainWithdrawn(msg.sender, depositorETHGain, LUSDLoss);
        emit UserDepositChanged(msg.sender, compoundedLUSDDeposit);

        ETH = ETH - depositorETHGain; // Using '-'
        emit StabilityPoolETHBalanceUpdated(ETH);
        emit EtherSent(msg.sender, depositorETHGain);

        borrowerOperations.moveETHGainToTrove{ value: depositorETHGain }(msg.sender, _upperHint, _lowerHint);
    }

    // --- LQTY issuance functions ---

    function _triggerLQTYIssuance(ICommunityIssuance _communityIssuance) internal {
        uint LQTYIssuance = _communityIssuance.issueLQTY();
       _updateG(LQTYIssuance);
    }

    function _updateG(uint _LQTYIssuance) internal {
        uint totalLUSD = totalLUSDDeposits; // cached to save an SLOAD
        /*
        * When total deposits is 0, G is not updated. In this case, the LQTY issued can not be obtained by later
        * depositors - it is missed out on, and remains in the balanceof the CommunityIssuance contract.
        *
        */
        if (totalLUSD == 0 || _LQTYIssuance == 0) {return;}

        uint LQTYPerUnitStaked;
        LQTYPerUnitStaked =_computeLQTYPerUnitStaked(_LQTYIssuance, totalLUSD);

        uint marginalLQTYGain = LQTYPerUnitStaked * P; // Using '*'
        scaleToG[currentScale] = scaleToG[currentScale] + marginalLQTYGain; // Using '+'

        emit G_Updated(scaleToG[currentScale], currentScale);
    }

    function _computeLQTYPerUnitStaked(uint _LQTYIssuance, uint _totalLUSDDeposits) internal returns (uint) {
        /*  
        * Calculate the LQTY-per-unit staked.  Division uses a "feedback" error correction, to keep the 
        * cumulative error low in the running total G:
        *
        * 1) Form a numerator which compensates for the floor division error that occurred the last time this 
        * function was called.  
        * 2) Calculate "per-unit-staked" ratio.
        * 3) Multiply the ratio back by its denominator, to reveal the current floor division error.
        * 4) Store this error for use in the next correction when this function is called.
         * 5) Note: static analysis tools complain about this "division before multiplication", however, it is intended.
         */
        uint LQTYNumerator = (_LQTYIssuance * DECIMAL_PRECISION) + lastLQTYError; // Using '*' and '+'

        uint LQTYPerUnitStaked = LQTYNumerator / _totalLUSDDeposits; // Using '/'
        lastLQTYError = LQTYNumerator - (LQTYPerUnitStaked * _totalLUSDDeposits); // Using '-' and '*'

        return LQTYPerUnitStaked;
    }

    // --- Liquidation functions ---

    function getMaxAmountToOffset() external view override returns (uint) {
        uint totalLUSD = totalLUSDDeposits; // cache
        // - If the SP has total deposits >= 1e18, we leave 1e18 in it untouched.
        // - If it has 0 < x < 1e18 total deposits, we leave x in it.
        uint256 lusdToLeaveInSP = LiquityMath._min(MIN_LUSD_IN_SP, totalLUSD);
        uint LUSDInSPForOffsets = totalLUSD - lusdToLeaveInSP; // safe, for the line above
        // Let’s avoid underflow in case of a tiny offset
        if ((LUSDInSPForOffsets * DECIMAL_PRECISION) <= lastLUSDLossError_Offset) { // Using '*'
            LUSDInSPForOffsets = 0;
        }

        return LUSDInSPForOffsets;
    }

    /*
    * Cancels out the specified debt against the LUSD contained in the Stability Pool (as far as possible)
    * and transfers the Trove's ETH collateral from ActivePool to StabilityPool.
    * Only called by liquidation functions in the TroveManager.
    */
    function offset(uint _debtToOffset, uint _collToAdd) external override {
        _requireCallerIsTroveManager();
        uint totalLUSD = totalLUSDDeposits; // cached to save an SLOAD
        if (totalLUSD == 0 || _debtToOffset == 0) { return; }

        _triggerLQTYIssuance(communityIssuance);

        (uint ETHGainPerUnitStaked,
            uint LUSDLossPerUnitStaked) = _computeRewardsPerUnitStaked(_collToAdd, _debtToOffset, totalLUSD);

        _updateRewardSumAndProduct(ETHGainPerUnitStaked, LUSDLossPerUnitStaked);  // updates S and P

        _moveOffsetCollAndDebt(_collToAdd, _debtToOffset);
    }

    // --- Offset helper functions ---

    function _computeRewardsPerUnitStaked(
        uint _collToAdd,
        uint _debtToOffset,
        uint _totalLUSDDeposits
    )
        internal
        returns (uint ETHGainPerUnitStaked, uint LUSDLossPerUnitStaked)
    {
        /*
        * Compute the LUSD and ETH rewards. Uses a "feedback" error correction, to keep
        * the cumulative error in the P and S state variables low:
        *
        * 1) Form numerators which compensate for the floor division errors that occurred the last time this 
        * function was called.  
        * 2) Calculate "per-unit-staked" ratios.
        * 3) Multiply each ratio back by its denominator, to reveal the current floor division error.
        * 4) Store these errors for use in the next correction when this function is called.
        * 5) Note: static analysis tools complain about this "division before multiplication", however, it is intended.
        */
        uint ETHNumerator = (_collToAdd * DECIMAL_PRECISION) + lastETHError_Offset; // Using '*' and '+'

        assert(_debtToOffset < _totalLUSDDeposits);
        uint LUSDLossNumerator;
        /* Let’s avoid underflow in case of a small offset
         * Per getMaxAmountToOffset, if the max used, this will never happen.
         * If the max is not used, then offset value is at least MN_NET_DEBT,
         * which means that total LUSD deposits when error was produced was around 2e21 LUSD.
         * See: https://github.com/liquity/dev/pull/417#issuecomment-805721292
         * As we are doing floor + 1 in the division, it will still offset something
         */
        if ((_debtToOffset * DECIMAL_PRECISION) <= lastLUSDLossError_Offset) { // Using '*'
            LUSDLossNumerator = 0;
        } else {
            LUSDLossNumerator = (_debtToOffset * DECIMAL_PRECISION) - lastLUSDLossError_Offset; // Using '*' and '-'
        }
        /*
         * Add 1 to make error in quotient positive. We want "slightly too much" LUSD loss,
         * which ensures the error in any given compoundedLUSDDeposit favors the Stability Pool.
         */
        LUSDLossPerUnitStaked = (LUSDLossNumerator / _totalLUSDDeposits) + 1; // Using '/' and '+'
        lastLUSDLossError_Offset = (LUSDLossPerUnitStaked * _totalLUSDDeposits) - LUSDLossNumerator; // Using '*' and '-'

        ETHGainPerUnitStaked = ETHNumerator / _totalLUSDDeposits; // Using '/'
        lastETHError_Offset = ETHNumerator - (ETHGainPerUnitStaked * _totalLUSDDeposits); // Using '-' and '*'

        return (ETHGainPerUnitStaked, LUSDLossPerUnitStaked);
    }

    // Update the Stability Pool reward sum S and product P
    function _updateRewardSumAndProduct(uint _ETHGainPerUnitStaked, uint _LUSDLossPerUnitStaked) internal {
        uint currentP = P;
        uint newP;

        assert(_LUSDLossPerUnitStaked <= DECIMAL_PRECISION);
        /*
        * The newProductFactor is the factor by which to change all deposits, due to the depletion of Stability Pool LUSD in the liquidation.
        * We make the product factor 0 if there was a pool-emptying. Otherwise, it is (1 - LUSDLossPerUnitStaked)
        */
        uint newProductFactor = DECIMAL_PRECISION - _LUSDLossPerUnitStaked; // Using '-'

        uint currentScaleCached = currentScale;
        uint currentS = scaleToSum[currentScaleCached];

        /*
        * Calculate the new S first, before we update P.
        * The ETH gain for any given depositor from a liquidation depends on the value of their deposit
        * (and the value of totalDeposits) prior to the Stability being depleted by the debt in the liquidation.
        *
        * Since S corresponds to ETH gain, and P to deposit loss, we update S first.
        */
        uint marginalETHGain = _ETHGainPerUnitStaked * currentP; // Using '*'
        uint newS = currentS + marginalETHGain; // Using '+'
        scaleToSum[currentScaleCached] = newS;
        emit S_Updated(newS, currentScaleCached);

        // If multiplying P by a non-zero product factor would reduce P below the scale boundary, increment the scale
        if ((currentP * newProductFactor) / DECIMAL_PRECISION < SCALE_FACTOR) { // Using '*' and '/'
            newP = (currentP * newProductFactor * SCALE_FACTOR) / DECIMAL_PRECISION; // Using '*' and '/'
            currentScaleCached = currentScaleCached + 1; // Using '+'
            // If it’s still smaller than the SCALE_FACTOR, increment scale again.
            // Afterwards it couldn’t happen again, as DECIMAL_PRECISION = SCALE_FACTOR^2
            if (newP < SCALE_FACTOR) {
                newP = (currentP * newProductFactor * (SCALE_FACTOR ** 2)) / DECIMAL_PRECISION; // Using '*' and '/'
                currentScaleCached = currentScaleCached + 1; // Using '+'
            }
            currentScale = currentScaleCached;
            emit ScaleUpdated(currentScaleCached);
        } else {
            newP = (currentP * newProductFactor) / DECIMAL_PRECISION; // Using '*' and '/'
        }

        assert(newP > 0);
        P = newP;

        emit P_Updated(newP);
    }

    function _moveOffsetCollAndDebt(uint _collToAdd, uint _debtToOffset) internal {
        IActivePool activePoolCached = activePool;

        // Cancel the liquidated LUSD debt with the LUSD in the stability pool
        activePoolCached.decreaseLUSDDebt(_debtToOffset);
        _decreaseLUSD(_debtToOffset);

        // Burn the debt that was successfully offset
        lusdToken.burn(address(this), _debtToOffset);

        activePoolCached.sendETH(address(this), _collToAdd);
    }

    function _decreaseLUSD(uint _amount) internal {
        uint newTotalLUSDDeposits = totalLUSDDeposits - _amount; // Using '-'
        require(newTotalLUSDDeposits >= MIN_LUSD_IN_SP, "Withdrawal must leave totalBoldDeposits >= MIN_LUSD_IN_SP");
        totalLUSDDeposits = newTotalLUSDDeposits;
        emit StabilityPoolLUSDBalanceUpdated(newTotalLUSDDeposits);
    }

    // --- Reward calculator functions for depositor and front end ---

    /* Calculates the ETH gain earned by the deposit since its last snapshots were taken.
    * Given by the formula:  E = d0 * (S - S(0))/P(0)
    * where S(0) and P(0) are the depositor's snapshots of the sum S and product P, respectively.
    * d0 is the last recorded deposit value.
    */
    function getDepositorETHGain(address _depositor) public view override returns (uint) {
        uint initialDeposit = deposits[_depositor].initialValue;

        if (initialDeposit == 0) { return 0; }

        Snapshots memory snapshots = depositSnapshots[_depositor];

        uint ETHGain = _getETHGainFromSnapshots(initialDeposit, snapshots);
        return ETHGain;
    }

    function _getETHGainFromSnapshots(uint initialDeposit, Snapshots memory snapshots) internal view returns (uint) {
        /*
        * Grab the sum 'S' from the scale at which the stake was made. The ETH gain may span up to one scale change.
        * If it does, the second portion of the ETH gain is scaled by 1e9.
        * If the gain spans no scale change, the second portion will be 0.
        */
        uint scaleSnapshot = snapshots.scale;
        uint S_Snapshot = snapshots.S;
        uint P_Snapshot = snapshots.P;

        uint firstPortion = scaleToSum[scaleSnapshot] - S_Snapshot; // Using '-'
        uint secondPortion = scaleToSum[scaleSnapshot + 1] / SCALE_FACTOR; // Using '+' and '/'

        uint ETHGain = (initialDeposit * (firstPortion + secondPortion)) / P_Snapshot / DECIMAL_PRECISION; // Using '*', '+', '/'

        return ETHGain;
    }

    /*
    * Calculate the LQTY gain earned by a deposit since its last snapshots were taken.
    * Given by the formula:  LQTY = d0 * (G - G(0))/P(0)
    * where G(0) and P(0) are the depositor's snapshots of the sum G and product P, respectively.
    * d0 is the last recorded deposit value.
    */
    function getDepositorLQTYGain(address _depositor) public view override returns (uint) {
        uint initialDeposit = deposits[_depositor].initialValue;
        if (initialDeposit == 0) {return 0;}

        address frontEndTag = deposits[_depositor].frontEndTag;

        /*
        * If not tagged with a front end, the depositor gets a 100% cut of what their deposit earned.
        * Otherwise, their cut of the deposit's earnings is equal to the kickbackRate, set by the front end through
        * which they made their deposit.
        */
        uint kickbackRate = frontEndTag == address(0) ? DECIMAL_PRECISION : frontEnds[frontEndTag].kickbackRate;

        Snapshots memory snapshots = depositSnapshots[_depositor];

        uint LQTYGain = (kickbackRate * _getLQTYGainFromSnapshots(initialDeposit, snapshots)) / DECIMAL_PRECISION; // Using '*' and '/'

        return LQTYGain;
    }

    /*
    * Return the LQTY gain earned by the front end. Given by the formula:  E = D0 * (G - G(0))/P(0)
    * where G(0) and P(0) are the depositor's snapshots of the sum G and product P, respectively.
    *
    * D0 is the last recorded value of the front end's total tagged deposits.
    */
    function getFrontEndLQTYGain(address _frontEnd) public view override returns (uint) {
        uint frontEndStake = frontEndStakes[_frontEnd];
        if (frontEndStake == 0) { return 0; }

        uint kickbackRate = frontEnds[_frontEnd].kickbackRate;
        uint frontEndShare = DECIMAL_PRECISION - kickbackRate; // Using '-'

        Snapshots memory snapshots = frontEndSnapshots[_frontEnd];

        uint LQTYGain = (frontEndShare * _getLQTYGainFromSnapshots(frontEndStake, snapshots)) / DECIMAL_PRECISION; // Using '*' and '/'
        return LQTYGain;
    }

    function _getLQTYGainFromSnapshots(uint initialStake, Snapshots memory snapshots) internal view returns (uint) {
       /*
        * Grab the sum 'G' from the scale at which the stake was made. The LQTY gain may span up to one scale change.
        * If it does, the second portion of the LQTY gain is scaled by 1e9.
        * If the gain spans no scale change, the second portion will be 0.
        */
        uint scaleSnapshot = snapshots.scale;
        uint G_Snapshot = snapshots.G;
        uint P_Snapshot = snapshots.P;

        uint firstPortion = scaleToG[scaleSnapshot] - G_Snapshot; // Using '-'
        uint secondPortion = scaleToG[scaleSnapshot + 1] / SCALE_FACTOR; // Using '+' and '/'

        uint LQTYGain = (initialStake * (firstPortion + secondPortion)) / P_Snapshot / DECIMAL_PRECISION; // Using '*', '+', '/'

        return LQTYGain;
    }

    // --- Compounded deposit and compounded front end stake ---

    /*
    * Return the user's compounded deposit. Given by the formula:  d = d0 * P/P(0)
    * where P(0) is the depositor's snapshot of the product P, taken when they last updated their deposit.
    */
    function getCompoundedLUSDDeposit(address _depositor) public view override returns (uint) {
        uint initialDeposit = deposits[_depositor].initialValue;
        if (initialDeposit == 0) { return 0; }

        Snapshots memory snapshots = depositSnapshots[_depositor];

        uint compoundedDeposit = _getCompoundedStakeFromSnapshots(initialDeposit, snapshots);
        return compoundedDeposit;
    }

    /*
    * Return the front end's compounded stake. Given by the formula:  D = D0 * P/P(0)
    * where P(0) is the depositor's snapshot of the product P, taken at the last time
    * when one of the front end's tagged deposits updated their deposit.
    *
    * The front end's compounded stake is equal to the sum of its depositors' compounded deposits.
    */
    function getCompoundedFrontEndStake(address _frontEnd) public view override returns (uint) {
        uint frontEndStake = frontEndStakes[_frontEnd];
        if (frontEndStake == 0) { return 0; }

        Snapshots memory snapshots = frontEndSnapshots[_frontEnd];

        uint compoundedFrontEndStake = _getCompoundedStakeFromSnapshots(frontEndStake, snapshots);
        return compoundedFrontEndStake;
    }

    // Internal function, used to calculcate compounded deposits and compounded front end stakes.
    function _getCompoundedStakeFromSnapshots(
        uint initialStake,
        Snapshots memory snapshots
    )
        internal
        view
        returns (uint)
    {
        uint snapshot_P = snapshots.P;
        uint scaleSnapshot = snapshots.scale;

        uint compoundedStake;
        uint scaleDiff = currentScale - scaleSnapshot; // Using '-'

        /* Compute the compounded stake. If a scale change in P was made during the stake's lifetime,
        * account for it. If more than one scale change was made, then the stake has decreased by a factor of
        * at least 1e-9 -- so return 0.
        */
        if (scaleDiff == 0) {
            compoundedStake = (initialStake * P) / snapshot_P; // Using '*' and '/'
        } else if (scaleDiff == 1) {
            compoundedStake = (initialStake * P) / snapshot_P / SCALE_FACTOR; // Using '*', '/'
        } else { // if scaleDiff >= 2
            compoundedStake = 0;
        }

        /*
        * If compounded deposit is less than a billionth of the initial deposit, return 0.
        *
        * NOTE: originally, this line was in place to stop rounding errors making the deposit too large. However, the error
        * corrections should ensure the error in P "favors the Pool", i.e. any given compounded deposit should slightly less
        * than it's theoretical value.
        *
        * Thus it's unclear whether this line is still really needed.
        */
        if (compoundedStake < initialStake / 1e9) {return 0;} // Using '/'

        return compoundedStake;
    }

    // --- Sender functions for LUSD deposit, ETH gains and LQTY gains ---

    // Transfer the LUSD tokens from the user to the Stability Pool's address, and update its recorded LUSD
    function _sendLUSDtoStabilityPool(address _address, uint _amount) internal {
        lusdToken.sendToPool(_address, address(this), _amount);
        uint newTotalLUSDDeposits = totalLUSDDeposits + _amount; // Using '+'
        totalLUSDDeposits = newTotalLUSDDeposits;
        emit StabilityPoolLUSDBalanceUpdated(newTotalLUSDDeposits);
    }

    function _sendETHGainToDepositor(uint _amount) internal {
        if (_amount == 0) {return;}
        uint newETH = ETH - _amount; // Using '-'
        ETH = newETH;
        emit StabilityPoolETHBalanceUpdated(newETH);
        emit EtherSent(msg.sender, _amount);

        (bool success, ) = msg.sender.call{ value: _amount }("");
        require(success, "StabilityPool: sending ETH failed");
    }

    // Send LUSD to user and decrease LUSD in Pool
    function _sendLUSDToDepositor(address _depositor, uint LUSDWithdrawal) internal {
        if (LUSDWithdrawal == 0) {return;}

        lusdToken.returnFromPool(address(this), _depositor, LUSDWithdrawal);
        _decreaseLUSD(LUSDWithdrawal);
    }

    // --- External Front End functions ---

    // Front end makes a one-time selection of kickback rate upon registering
    function registerFrontEnd(uint _kickbackRate) external override {
        _requireFrontEndNotRegistered(msg.sender);
        _requireUserHasNoDeposit(msg.sender);
        _requireValidKickbackRate(_kickbackRate);

        frontEnds[msg.sender].kickbackRate = _kickbackRate;
        frontEnds[msg.sender].registered = true;

        emit FrontEndRegistered(msg.sender, _kickbackRate);
    }

    // --- Stability Pool Deposit Functionality ---

    function _setFrontEndTag(address _depositor, address _frontEndTag) internal {
        deposits[_depositor].frontEndTag = _frontEndTag;
        emit FrontEndTagSet(_depositor, _frontEndTag);
    }


    function _updateDepositAndSnapshots(address _depositor, uint _newValue) internal {
        deposits[_depositor].initialValue = _newValue;

        if (_newValue == 0) {
            delete deposits[_depositor].frontEndTag;
            delete depositSnapshots[_depositor];
            emit DepositSnapshotUpdated(_depositor, 0, 0, 0);
            return;
        }
        uint currentScaleCached = currentScale;
        uint currentP = P;

        // Get S and G for the current scale
        uint currentS = scaleToSum[currentScaleCached];
        uint currentG = scaleToG[currentScaleCached];

        // Record new snapshots of the latest running product P, sum S, and sum G, for the depositor
        depositSnapshots[_depositor].P = currentP;
        depositSnapshots[_depositor].S = currentS;
        depositSnapshots[_depositor].G = currentG;
        depositSnapshots[_depositor].scale = currentScaleCached;

        emit DepositSnapshotUpdated(_depositor, currentP, currentS, currentG);
    }

    function _updateFrontEndStakeAndSnapshots(address _frontEnd, uint _newValue) internal {
        frontEndStakes[_frontEnd] = _newValue;

        if (_newValue == 0) {
            delete frontEndSnapshots[_frontEnd];
            emit FrontEndSnapshotUpdated(_frontEnd, 0, 0);
            return;
        }

        uint currentScaleCached = currentScale;
        uint currentP = P;

        // Get G for the current scale
        uint currentG = scaleToG[currentScaleCached];

        // Record new snapshots of the latest running product P and sum G for the front end
        frontEndSnapshots[_frontEnd].P = currentP;
        frontEndSnapshots[_frontEnd].G = currentG;
        frontEndSnapshots[_frontEnd].scale = currentScaleCached;

        emit FrontEndSnapshotUpdated(_frontEnd, currentP, currentG);
    }

    function _payOutLQTYGains(ICommunityIssuance _communityIssuance, address _depositor, address _frontEnd) internal {
        // Pay out front end's LQTY gain
        if (_frontEnd != address(0)) {
            uint frontEndLQTYGain = getFrontEndLQTYGain(_frontEnd);
            _communityIssuance.sendLQTY(_frontEnd, frontEndLQTYGain);
            emit LQTYPaidToFrontEnd(_frontEnd, frontEndLQTYGain);
        }

        // Pay out depositor's LQTY gain
        uint depositorLQTYGain = getDepositorLQTYGain(_depositor);
        _communityIssuance.sendLQTY(_depositor, depositorLQTYGain);
        emit LQTYPaidToDepositor(_depositor, depositorLQTYGain);
    }

    // --- 'require' functions ---

    function _requireCallerIsActivePool() internal view {
        require( msg.sender == address(activePool), "StabilityPool: Caller is not ActivePool");
    }

    function _requireCallerIsTroveManager() internal view {
        require(msg.sender == address(troveManager), "StabilityPool: Caller is not TroveManager");
    }

    function _requireNoUnderCollateralizedTroves() internal {
        uint price = priceFeed.fetchPrice();
        address lowestTrove = sortedTroves.getLast();
        uint ICR = troveManager.getCurrentICR(lowestTrove, price);
        require(ICR >= MCR, "StabilityPool: Cannot withdraw while there are troves with ICR < MCR");
    }

    function _requireUserHasDeposit(uint _initialDeposit) internal pure {
        require(_initialDeposit > 0, 'StabilityPool: User must have a non-zero deposit');
    }

     function _requireUserHasNoDeposit(address _address) internal view {
        uint initialDeposit = deposits[_address].initialValue;
        require(initialDeposit == 0, 'StabilityPool: User must have no deposit');
    }

    function _requireNonZeroAmount(uint _amount) internal pure {
        require(_amount > 0, 'StabilityPool: Amount must be non-zero');
    }

    function _requireUserHasTrove(address _depositor) internal view {
        require(troveManager.getTroveStatus(_depositor) == 1, "StabilityPool: caller must have an active trove to withdraw ETHGain to");
    }

    function _requireUserHasETHGain(address _depositor) internal view {
        uint ETHGain = getDepositorETHGain(_depositor);
        require(ETHGain > 0, "StabilityPool: caller must have non-zero ETH Gain");
    }

    function _requireFrontEndNotRegistered(address _address) internal view {
        require(!frontEnds[_address].registered, "StabilityPool: must not already be a registered front end");
    }

     function _requireFrontEndIsRegisteredOrZero(address _address) internal view {
        require(frontEnds[_address].registered || _address == address(0),
            "StabilityPool: Tag must be a registered front end, or the zero address");
    }

    function  _requireValidKickbackRate(uint _kickbackRate) internal pure {
        require (_kickbackRate <= DECIMAL_PRECISION, "StabilityPool: Kickback rate must be in range [0,1]");
    }

    // --- Fallback function ---

    receive() external payable {
        _requireCallerIsActivePool();
        ETH = ETH + msg.value; // Using '+'
        emit StabilityPoolETHBalanceUpdated(ETH);
    }
}
