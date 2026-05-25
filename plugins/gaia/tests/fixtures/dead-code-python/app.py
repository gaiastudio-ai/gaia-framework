def used():
    return 1


def unused_high():   # vulture: 95% confidence dead
    return 2


unused_var = 3       # vulture: 70% confidence (below threshold)


print(used())
