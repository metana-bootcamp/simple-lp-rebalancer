## Just-In-Time Rebalancer

* As swap happen through, the price of pool shift.
* Positions there were active could become inactive if price shifts enough
and previously inactive positions can becomne active
* The LP who consitently want to get paud out LP fees need to periodically rebalance there liquidity (i.e. update the tick range) to make sure there liquidity is considered active

* Uniswap doesn't automatically rebalance positions for LPs, since some LPs may not want to provide that liquidity outside theer predetermined range.

### Important Considerations for JIT in V3 and V4
* In V3 , The LP needed to incur gas fees of adding/removing liquidity around the swap transaction. 
   * Assuming a hook design where this can happen in `beforeSwap` and `afterSwap` - this cost can be offloaded to swapper as it is incurred during execution of `swap` transaction

* In V3, Liquidity needed to be added right before swap, and removed right after the sswap.
   * This was done through Flashbots bundles and required the LP to therefore pay a searcherfee, increasing there overall cost. By providing this liquidity in hooks instead, no seacher fee is required and you don't need to beat other searchers either since you have accerss to the true state of the pool during execution `beforeSwap`

* In V3, due to this happening through MEV Bundles, LPs could simultaneously find a route on alternative liquidity venues where they could hedge there trade. However, since hooks cannot synchronously fetch off chain data, this implies the LP must have access to a liquidity venue where they can safely assume they will be able to hedge the transaction at lower cost basis than the AMM swapper

### Mechanism
* LP observe a large swap tx
* LP Add sizeable liquidity to pool right before swap concentrated in a single tick that the swap will be in a range for
* LP lets the swap execute and receive large portion of LP fee since the swap will mostly go through their liquidity
* Remove the liquidty and fees accrued immediately

#### At the core, we want the liquidity to be added just in time through `beforeSwap` and then removed `afterSwap`. To do so, the hook must :

##### Case(1)
* Own the liquidity the LP plans to use for this strategy, allowing the hook to provision the liquidity automatically
* This means the LP must either give approval over their tokens, or actually trasnfer the tokens, to the hook contract upfront.
* For example, the LP can send 10M USDC to the hook contract if the hook is configured such that the swaps around 9-10 million USD will be treated through JIT liquidity
* Side effect : the hook must also have a way for the LP to withdraw their tokens back out - either through some sort of receipt token they get back or just some information stored in the hook contract.

##### Case(2)
* Have some logic to differeniate betweena regular swap and a large swap, since this strategy is only really profitable on large swaps.
* This is fairly open ended depending on how "general purpose" the hook is meant to be. Assuming this is a relatively general purpose hook that wants to cater to multiple LPs, not a single market maker running their own AMM pools, may be this should be somehow configurable!!.
* The LP, when providing tokens to the hook to use for this strategy, can perhaps sepcify some conditions which cna be evaluated to determine if a given swap is considered large enough to perfor this strategy on.
* Alternatively, it can be made more simpler and perhaps just designed as being triggered if the swap is trading a certain percentage of pool reserves.

##### Case(3)
* If possible, have ability to hedge the transaction
* This is possible if alternative liquidity venue in question is also onchain.
*In this case, the hook can execute the hedge transaction inside `afterSwap` on the alternative source. This situation is rare per say, as a large informed swapper would likely just thorugh the alternative source if a highly liquidity dense lower fee pool was available to them.