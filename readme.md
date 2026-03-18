# Yield.jl

An experimental milk yield mass-balance model.

# tl;dr

 * install [Julia](https://julialang.org/downloads/)
 * install some other dev tools (optional)
   * [VSCode](https://code.visualstudio.com/)
   * [Git For Windows](https://gitforwindows.org/) (If you're on windows, make sure to install git bash)
 * In a unix-shell like environment type `./admin` and the tests should run.
   The first time will take a while - the admin script will install and precompile all the
   necessary Julia packages.  You can type `./admin watch` to run tests every time a file changes.


# What is this?

The amount of milk it will take to make a given quantity of a final product - for example skim
milk powder - depends on the target composition of the product, the processes used to make the
product, and the composition of the milk (and any other ingredients) on the day the product is made.

Making the product means running the milk (and subsequent intermediate streams) through a number of
unit processes, which respect conservation of mass (hence this being a mass-balance model).
For example, to make skim powder, you
 * separate the milk into skim and cream
 * ultrafilter some of the skim into permeate and lactose
 * mix skim, cream and permeate to meet the targets for the product
 * evaporate the mixture to about 50% solids
 * dry the mixture to about 95% solids

As you do that, you might:
 * take the excess cream, separate in into butter and buttermilk to make butter
 * take the retentate and make it into Milk Protein Concentrate
 * take the buttermilk from the butter and either make it into buttermilk, or mix it into wholemilk
   powder.

So there's a whole network of connected unit processes involved in making dairy products, and
production of the products are interlinked.

This tool aims to provide models for each unit operation, a system for specifying "recipes" (the
sequence of unit operations, targets and operating parameters) for each product, and a mechanism
to compute yields.


 # How does it work?

 It's possible to build models that start at the milk, and work forwards, computing the output
 composition and volumes from the separator, and then working out how to mix components to get a
 desired output composition.  However, these models fail when information needs to be passed
 backwards from the product to intermediate processes.  In the example above, I listed, mixing,
 evaporation and drying as separate processes, where the product targed composition is the dry
 composition.  To know the target composition of the mixed liquid, you have to work backwards from
 the dry, and that doesn't work in a forward-only model.

 In forward only models, you have to mix, evaporate and dry in one step, so that the final
 composition is available to the unit process.

 The new approach in this model is that we don't compute step-by-step through the the processes,
 instead, we assemble all the equations implied by each process, and then use a solver to sort
 everything out.  It's an open question as to whether this will work in general.

 Another potential advantage of the approach (also not proven) is that this could allow us to fit
 model parameters.  Each unit process has a number of parameters (losses, component ratios,
 retention coefficients) that govern how it runs.  The values of these parameters are only
 approximate.  If we could build a model, and run it in anther mode where we gave it historical
 milk composition and quantity data, as well as quantities of finished products, could we find the
 set of parameters that best explained production, and so would be best for forecasting?


# What processes are modelled?

Not everything is modelled yet, and the models are not in any kind of final state.

## Separation

Separation is commonly used to separate milk fat out of milk and into cream (leaving low-fat skim),
using the relative densities of fat and water (and the other components) for the separation.
In separation, the input stream will have uncontrolled fraction of a component - nearly always fat -
for example, milk might be 4.3% fat - and there are two output streams, where the fraction of the
component is controlled - for example, skim might be 0.001% fat, and cream might be 42% fat.

Common separation processes include:
 * milk into skim and cream;
 * cream into AMF or butter and buttermilk;
 * buttermilk into secondary skim and beta serum;
 * whole whey into whey and whey cream.

A useful mental model for separation is that all the fat is removed from the milk, and all the
remaining liquid is split into two unequal parts of the same compostion.  The fat is then re-added
in unequal amounts to the to the two parts.  The unequal parts of fat and remaining liquds are
chosen so that the fat targets of the two parts are met.

When modelling separation, we assume:
 1. all mass, including water, is conserved;
 2. the uncontrolled components remain in solution and volume the mass ratios;
 3. one of the outflows has a higher concentration of fat than the inflow, the other is lower
    (otherwise the maths doesn't work and we get negative flows).

Taking the example of milk, skim and cream, if we define:
 * $F_m$ as the fraction of fat in the milk;
 * $F_s$ as the fraction of fat in the skim;
 * $F_c$ as the fraction of fat in the cream;
 * $S$ as the fraction of the milk we turn into skim;
 * $C$ as the fraction of the milk we turn into cream;
 * $O_m$, $O_s$ and $O_c$ as the fractions of other components (protein, lactose, minerals...) in
   the milk, skim and cream respectively,

then, assuming we use one unit of milk, by mass conservation:

$$C = 1 - S$$

and by fat conservation:

$$F_m = SF_s + (1 - S)F_c$$

leading to:

$$S = \frac{F_m - F_c}{F_s - F_c}$$

As long as assumption 3 holds, S will neither be less than zero nor greater than one.

For the uncontrolled components, the mental model above means that their non-fat fractions remain
constant:

$$\frac{O_m}{1-F_m} = \frac{O_s}{1-F_s}$$

and so:

$$O_s = O_m\frac{1-F_s}{1-F_m}$$

Which applies for protein, lactose, minerals and other components.  It works for cream by
substituting $O_c$ and $F_c$ for $O_s$ and $F_s$.


## Mixing

Liquid streams are mixed to meet product targets, for example "Standard" milk powders are made by
mixing three streams of liquids:
 * a source of protein (usually skim milk);
 * a source of fat (usually cream); and
 * a source of lactose (either permeate or pure lactose).

 By mixing three streams, three targets can be met, which a usually:
  * a minimum protein content;
  * a maximum or minimum fat content; and
  * total solids (or moisture content).

The targets are not met directly in the output of the mix (which is mostly water, and not, say,
26% protein), but after drying.

Given:
 * compositions of the input liquids
 * quantities of input liquids

The mix module computes the composition of the output.

Suppose we're mixing $S$ kg of skim, $C$ kg of cream and $L$ kg of permeate (think "L for Lactose"),
then the fraction protein in the mixture is:

$$P = \frac{SP_s + CP_c + LP_l}{S + C + L}$$

Equally, the fat and total solids in the mixture will be:

$$F = \frac{SF_s + CF_c + LF_l}{S + C + L}$$
$$T = \frac{ST_s + CT_c + LT_l}{S + C + L}$$

The solver can solve for any of the factors - given enough knowns.  Usually, the compositions of the
inputs are known, as is something about the composition of the output (it's target composition after
drying) and quantities of each input stream are the model output.


## Filtration

In filtration, milk is passed through a filter with tiny holes (or some kind of ion exchange
mechanism) and some components (the small ones like lactose) permeate through the filter to the
"permeate" side, while larger components (the protein and fat) don't pass through the filter and are
retained on the retentate side.

A filter is characterised by its retention coefficients.  For each component this coefficient
specifies how much of the component is retained, and how much permeates through the filter.
For example, for protein, typically, about 95% of the protein does not pass through the filter, so
the retention coefficient is 0.95.
Some components (typically the lactose) behave differently and remain in solution, the amount of
lactose on each side the filter is proportional to the amount of liquid on each side - and you can
alter where the liquid goes by adjusting the pressure pushing the liquid through the filter (or with
wash water on the permeate side, in which case the lactose is proportional to the fraction of
"original" liquid on each side).

Another key parameter for a filter is the "volume concentration factor" (VCF) - the quantity of the
original liquid divided by the total liquid on the retention side of the filter.  For example, if
we start with one litre of liquid, and 500ml ends up on the retention side, the VCF is 2.  As
alluded to above, the VCF can be controlled with the pressure on the retention side of the filter
(a higher pressure means less liquid on the retentate side, and hence a higher VCF) or by using wash
water on the permeate side.

A helpful mental model for a filter is to imagine that the filtered components are removed from the
solution and each broken into two dry piles: for protein, 95% would be in the retentate pile, and
5% in the permeate pile.
Then the liquid is split into two quantities.  For the retentate, so that the total quantity of
liquid and retained components matches the CF, and the rest in the permeate.
The in solution components follow the quantities of liquid.

Assuming that there is 1l of inflow liquid, the VCF is $v$, the
fraction of component $f$ (for "filtered") in the inflow is $f_i$ and the retention coefficient for
the component is $r_f$, then the fraction of the component in the retentate $f_r$ will be:

$$f_r = f_i r_f v$$

if we define $v'$ as the concentration factor in the permeate so that $v' = \frac{v}{v - 1}$, then
the fraction of the component in the permeate is:

$$f_p = f_i (1 - r_f) v'$$

In-solution components have a subtlety - we must subract the quantity of filtered components from
the total liquid quantities to get the quantity and in solution components.

If $F_i$ is the total quantity of filtered components in the input, and correspondingly
$F_r = \sum_{f\in F}{f_i r_f}$ and $F_p = \sum_{f\in F}{f_i (1 - r_f)}$ are the quantities of
filtered components in the permeate and retentate then, the fraction of an in-solution component
$s_r$ in the retentate is:

$$s_r = s_i \frac{1 - F_r v}{1 - F_i}$$

and for the permeate:

$$s_p = s_i \frac{1 - F_p v'}{1 - F_i}$$
